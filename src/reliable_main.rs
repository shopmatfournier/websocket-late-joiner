use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Query, State,
    },
    response::{Html, Response},
    routing::get,
    Router,
};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{broadcast, RwLock};
use tokio::time::{interval, Instant};
use tower_http::cors::CorsLayer;
use tracing::{info, warn};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum EventType {
    #[serde(rename = "draw")]
    Draw { x1: f32, y1: f32, x2: f32, y2: f32, color: String },
    #[serde(rename = "circle")]
    Circle { cx: f32, cy: f32, radius: f32, color: String },
    #[serde(rename = "move")]
    Move { object_id: String, x: f32, y: f32 },
    #[serde(rename = "delete")]
    Delete { object_id: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollaborativeEvent {
    pub id: String,
    pub user_id: String,
    pub sequence_number: u64,  // Global sequence number
    pub timestamp: u64,
    pub event: EventType,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ServerMessage {
    #[serde(rename = "sync_start")]
    SyncStart { sync_id: String },
    #[serde(rename = "snapshot")]
    Snapshot { events: Vec<CollaborativeEvent>, last_sequence: u64 },
    #[serde(rename = "sync_complete")]
    SyncComplete { current_sequence: u64 },
    #[serde(rename = "event")]
    Event { event: CollaborativeEvent, ack_required: bool },
    #[serde(rename = "user_joined")]
    UserJoined { user_id: String },
    #[serde(rename = "user_left")]
    UserLeft { user_id: String },
    #[serde(rename = "heartbeat")]
    Heartbeat { sequence: u64 },
    #[serde(rename = "gap_detected")]
    GapDetected { missing_sequences: Vec<u64> },
    #[serde(rename = "resend_events")]
    ResendEvents { events: Vec<CollaborativeEvent> },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ClientMessage {
    #[serde(rename = "ack")]
    Ack { sequence_number: u64 },
    #[serde(rename = "gap_report")]
    GapReport { last_received_sequence: u64, missing_sequences: Vec<u64> },
    #[serde(rename = "heartbeat_response")]
    HeartbeatResponse { sequence: u64 },
}

#[derive(Debug)]
pub struct UserConnection {
    sender: broadcast::Sender<ServerMessage>,
    last_ack_sequence: u64,
    last_heartbeat: Instant,
    pending_events: BTreeMap<u64, CollaborativeEvent>, // Events waiting for ACK
}

pub struct SessionState {
    events: BTreeMap<u64, CollaborativeEvent>, // Ordered by sequence number
    sequence_counter: u64,
    users: HashMap<String, UserConnection>,
}

impl SessionState {
    fn new() -> Self {
        Self {
            events: BTreeMap::new(),
            sequence_counter: 0,
            users: HashMap::new(),
        }
    }

    fn next_sequence(&mut self) -> u64 {
        self.sequence_counter += 1;
        self.sequence_counter
    }

    fn add_event(&mut self, mut event: CollaborativeEvent) -> u64 {
        let sequence = self.next_sequence();
        event.sequence_number = sequence;
        self.events.insert(sequence, event.clone());
        
        // Store event as pending for all users
        for user_conn in self.users.values_mut() {
            user_conn.pending_events.insert(sequence, event.clone());
        }
        
        // Cleanup old events (keep last 10000)
        if self.events.len() > 10000 {
            let keys_to_remove: Vec<_> = self.events.keys().take(self.events.len() - 10000).cloned().collect();
            for key in keys_to_remove {
                self.events.remove(&key);
            }
        }
        
        sequence
    }

    fn acknowledge_event(&mut self, user_id: &str, sequence: u64) {
        if let Some(user_conn) = self.users.get_mut(user_id) {
            user_conn.last_ack_sequence = sequence;
            user_conn.pending_events.remove(&sequence);
        }
    }

    fn get_events_since(&self, last_sequence: u64) -> Vec<CollaborativeEvent> {
        self.events
            .range(last_sequence + 1..)
            .map(|(_, event)| event.clone())
            .collect()
    }

    fn get_events_for_sequences(&self, sequences: &[u64]) -> Vec<CollaborativeEvent> {
        sequences
            .iter()
            .filter_map(|seq| self.events.get(seq).cloned())
            .collect()
    }

}

type AppState = Arc<RwLock<SessionState>>;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    
    let state = Arc::new(RwLock::new(SessionState::new()));
    
    // Start heartbeat task
    let heartbeat_state = state.clone();
    tokio::spawn(async move {
        let mut interval = interval(Duration::from_secs(30));
        loop {
            interval.tick().await;
            heartbeat_task(&heartbeat_state).await;
        }
    });
    
    let app = Router::new()
        .route("/", get(serve_client))
        .route("/ws", get(websocket_handler))
        .layer(CorsLayer::permissive())
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3000")
        .await
        .unwrap();
    
    info!("Reliable WebSocket server running on http://127.0.0.1:3000");
    
    axum::serve(listener, app).await.unwrap();
}

async fn heartbeat_task(state: &AppState) {
    let mut session = state.write().await;
    let current_sequence = session.sequence_counter;
    
    let heartbeat = ServerMessage::Heartbeat { 
        sequence: current_sequence 
    };
    
    let mut disconnected_users = Vec::new();
    
    for (user_id, user_conn) in &mut session.users {
        if user_conn.last_heartbeat.elapsed() > Duration::from_secs(90) {
            disconnected_users.push(user_id.clone());
        } else {
            let _ = user_conn.sender.send(heartbeat.clone());
        }
    }
    
    // Remove disconnected users
    for user_id in disconnected_users {
        session.users.remove(&user_id);
    }
}

async fn serve_client() -> Html<&'static str> {
    Html(include_str!("../reliable_client.html"))
}

async fn websocket_handler(
    ws: WebSocketUpgrade,
    Query(params): Query<ConnectQuery>,
    State(state): State<AppState>,
) -> Response {
    ws.on_upgrade(|socket| handle_socket(socket, params, state))
}

#[derive(Debug, Deserialize)]
pub struct ConnectQuery {
    user_id: String,
    last_known_sequence: Option<u64>,
}

async fn handle_socket(socket: WebSocket, params: ConnectQuery, state: AppState) {
    let user_id = params.user_id.clone();
    info!("User {} connecting with last_known_sequence: {:?}", user_id, params.last_known_sequence);

    let (tx, mut rx) = broadcast::channel::<ServerMessage>(1000);
    
    // Add user to session
    {
        let mut session = state.write().await;
        let user_conn = UserConnection {
            sender: tx.clone(),
            last_ack_sequence: params.last_known_sequence.unwrap_or(0),
            last_heartbeat: Instant::now(),
            pending_events: BTreeMap::new(),
        };
        session.users.insert(user_id.clone(), user_conn);
    }

    let (mut sender, mut receiver) = socket.split();

    // Send synchronization messages
    let sync_id = Uuid::new_v4().to_string();
    
    // 1. Sync start
    let sync_start = ServerMessage::SyncStart { sync_id };
    if sender.send(Message::Text(serde_json::to_string(&sync_start).unwrap())).await.is_err() {
        return;
    }

    // 2. Send snapshot with sequence information
    let (events_to_send, last_sequence) = {
        let session = state.read().await;
        let last_seq = params.last_known_sequence.unwrap_or(0);
        let events = session.get_events_since(last_seq);
        (events, session.sequence_counter)
    };
    
    if !events_to_send.is_empty() {
        let snapshot = ServerMessage::Snapshot { 
            events: events_to_send,
            last_sequence,
        };
        if sender.send(Message::Text(serde_json::to_string(&snapshot).unwrap())).await.is_err() {
            return;
        }
    }

    // 3. Sync complete
    let sync_complete = ServerMessage::SyncComplete { 
        current_sequence: last_sequence 
    };
    if sender.send(Message::Text(serde_json::to_string(&sync_complete).unwrap())).await.is_err() {
        return;
    }

    // Notify other users
    broadcast_to_others(&state, &user_id, ServerMessage::UserJoined { user_id: user_id.clone() }).await;

    let state_clone = state.clone();
    let user_id_clone = user_id.clone();
    
    // Task to handle incoming messages
    let incoming_task = tokio::spawn(async move {
        while let Some(msg) = receiver.next().await {
            match msg {
                Ok(Message::Text(text)) => {
                    // First try to parse as ClientMessage (ACKs, gap reports)
                    if let Ok(client_msg) = serde_json::from_str::<ClientMessage>(&text) {
                        handle_client_message(client_msg, &user_id_clone, &state_clone).await;
                        continue;
                    }
                    
                    // Then try to parse as EventType (actual events)
                    match serde_json::from_str::<EventType>(&text) {
                        Ok(event_type) => {
                            let event = CollaborativeEvent {
                                id: Uuid::new_v4().to_string(),
                                user_id: user_id_clone.clone(),
                                sequence_number: 0, // Will be set by add_event
                                timestamp: SystemTime::now()
                                    .duration_since(UNIX_EPOCH)
                                    .unwrap()
                                    .as_millis() as u64,
                                event: event_type,
                            };

                            let _sequence = {
                                let mut session = state_clone.write().await;
                                session.add_event(event.clone())
                            };

                            // Broadcast with ACK requirement for reliable delivery
                            let server_msg = ServerMessage::Event { 
                                event: event.clone(),
                                ack_required: true,
                            };
                            broadcast_to_all(&state_clone, server_msg).await;
                        }
                        Err(e) => {
                            warn!("Failed to parse message from {}: {}", user_id_clone, e);
                        }
                    }
                }
                Ok(Message::Close(_)) => break,
                Err(e) => {
                    warn!("WebSocket error for user {}: {}", user_id_clone, e);
                    break;
                }
                _ => {}
            }
        }
    });

    // Task to handle outgoing messages
    let outgoing_task = tokio::spawn(async move {
        while let Ok(msg) = rx.recv().await {
            let json = serde_json::to_string(&msg).unwrap();
            if sender.send(Message::Text(json)).await.is_err() {
                break;
            }
        }
    });

    // Wait for either task to complete
    tokio::select! {
        _ = incoming_task => {},
        _ = outgoing_task => {},
    }

    // Cleanup
    {
        let mut session = state.write().await;
        session.users.remove(&user_id);
    }

    broadcast_to_others(&state, &user_id, ServerMessage::UserLeft { user_id: user_id.clone() }).await;
    info!("User {} disconnected", user_id);
}

async fn handle_client_message(msg: ClientMessage, user_id: &str, state: &AppState) {
    match msg {
        ClientMessage::Ack { sequence_number } => {
            let mut session = state.write().await;
            session.acknowledge_event(user_id, sequence_number);
        }
        ClientMessage::GapReport { last_received_sequence: _, missing_sequences } => {
            let session = state.read().await;
            let events = session.get_events_for_sequences(&missing_sequences);
            drop(session);
            
            if !events.is_empty() {
                if let Some(user_conn) = {
                    let session = state.read().await;
                    session.users.get(user_id).map(|conn| conn.sender.clone())
                } {
                    let resend_msg = ServerMessage::ResendEvents { events };
                    let _ = user_conn.send(resend_msg);
                }
            }
        }
        ClientMessage::HeartbeatResponse { sequence: _ } => {
            let mut session = state.write().await;
            if let Some(user_conn) = session.users.get_mut(user_id) {
                user_conn.last_heartbeat = Instant::now();
            }
        }
    }
}

async fn broadcast_to_all(state: &AppState, message: ServerMessage) {
    let session = state.read().await;
    for (_, user_conn) in &session.users {
        let _ = user_conn.sender.send(message.clone());
    }
}

async fn broadcast_to_others(state: &AppState, sender_user_id: &str, message: ServerMessage) {
    let session = state.read().await;
    for (user_id, user_conn) in &session.users {
        if user_id != sender_user_id {
            let _ = user_conn.sender.send(message.clone());
        }
    }
}