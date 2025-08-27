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
    collections::HashMap,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::{broadcast, RwLock};
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
    pub timestamp: u64,
    pub event: EventType,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ServerMessage {
    #[serde(rename = "sync_start")]
    SyncStart { sync_id: String },
    #[serde(rename = "snapshot")]
    Snapshot { events: Vec<CollaborativeEvent> },
    #[serde(rename = "sync_complete")]
    SyncComplete { current_version: u64 },
    #[serde(rename = "event")]
    Event { event: CollaborativeEvent },
    #[serde(rename = "user_joined")]
    UserJoined { user_id: String },
    #[serde(rename = "user_left")]
    UserLeft { user_id: String },
}

#[derive(Debug, Deserialize)]
pub struct ConnectQuery {
    user_id: String,
    last_known_version: Option<u64>,
}

pub struct SessionState {
    events: Vec<CollaborativeEvent>,
    version: u64,
    users: HashMap<String, broadcast::Sender<ServerMessage>>,
}

impl SessionState {
    fn new() -> Self {
        Self {
            events: Vec::new(),
            version: 0,
            users: HashMap::new(),
        }
    }

    fn add_event(&mut self, event: CollaborativeEvent) {
        self.version += 1;
        self.events.push(event);
        
        // Simple cleanup: keep only last 1000 events
        if self.events.len() > 1000 {
            self.events.drain(..self.events.len() - 1000);
        }
    }

    fn get_events_since(&self, version: Option<u64>) -> Vec<CollaborativeEvent> {
        match version {
            Some(v) => {
                // Find events after the given version
                // In a real implementation, you'd use proper indexing
                self.events.iter()
                    .filter(|event| {
                        event.timestamp > v
                    })
                    .cloned()
                    .collect()
            }
            None => self.events.clone(), // New user, send all events
        }
    }
}

type AppState = Arc<RwLock<SessionState>>;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    
    let state = Arc::new(RwLock::new(SessionState::new()));
    
    let app = Router::new()
        .route("/", get(serve_client))
        .route("/ws", get(websocket_handler))
        .layer(CorsLayer::permissive())
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:3000")
        .await
        .unwrap();
    
    info!("Server running on http://127.0.0.1:3000");
    info!("Open http://127.0.0.1:3000 in your browser to test the WebSocket collaboration");
    
    axum::serve(listener, app).await.unwrap();
}

async fn serve_client() -> Html<&'static str> {
    Html(include_str!("../client.html"))
}

async fn websocket_handler(
    ws: WebSocketUpgrade,
    Query(params): Query<ConnectQuery>,
    State(state): State<AppState>,
) -> Response {
    ws.on_upgrade(|socket| handle_socket(socket, params, state))
}

async fn handle_socket(socket: WebSocket, params: ConnectQuery, state: AppState) {
    let user_id = params.user_id.clone();
    info!("User {} connecting", user_id);

    // Create a broadcast channel for this user
    let (tx, mut rx) = broadcast::channel::<ServerMessage>(100);
    
    // Phase 1: Synchronization - Add user to session and send snapshot
    {
        let mut session = state.write().await;
        session.users.insert(user_id.clone(), tx.clone());
    }

    // Split the socket for concurrent reading and writing
    let (mut sender, mut receiver) = socket.split();

    // Send synchronization messages
    let sync_id = Uuid::new_v4().to_string();
    
    // 1. Sync start
    let sync_start = ServerMessage::SyncStart { sync_id: sync_id.clone() };
    if sender.send(Message::Text(serde_json::to_string(&sync_start).unwrap())).await.is_err() {
        return;
    }

    // 2. Send snapshot (events since last known version)
    let events_to_send = {
        let session = state.read().await;
        session.get_events_since(params.last_known_version)
    };
    
    if !events_to_send.is_empty() {
        let snapshot = ServerMessage::Snapshot { events: events_to_send };
        if sender.send(Message::Text(serde_json::to_string(&snapshot).unwrap())).await.is_err() {
            return;
        }
        
        // Add artificial delay to demonstrate the race condition
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }

    // 3. Sync complete
    let current_version = {
        let session = state.read().await;
        session.version
    };
    
    let sync_complete = ServerMessage::SyncComplete { current_version };
    if sender.send(Message::Text(serde_json::to_string(&sync_complete).unwrap())).await.is_err() {
        return;
    }

    // Notify other users that someone joined
    broadcast_to_others(&state, &user_id, ServerMessage::UserJoined { user_id: user_id.clone() }).await;

    info!("User {} synchronized", user_id);

    // Phase 2: Real-time communication
    let state_clone = state.clone();
    let user_id_clone = user_id.clone();
    
    // Task to handle incoming messages from the client
    let incoming_task = tokio::spawn(async move {
        while let Some(msg) = receiver.next().await {
            match msg {
                Ok(Message::Text(text)) => {
                    match serde_json::from_str::<EventType>(&text) {
                        Ok(event_type) => {
                            let event = CollaborativeEvent {
                                id: Uuid::new_v4().to_string(),
                                user_id: user_id_clone.clone(),
                                timestamp: SystemTime::now()
                                    .duration_since(UNIX_EPOCH)
                                    .unwrap()
                                    .as_millis() as u64,
                                event: event_type,
                            };

                            // Add event to session state
                            {
                                let mut session = state_clone.write().await;
                                session.add_event(event.clone());
                            }

                            // Broadcast to all connected users
                            broadcast_to_all(&state_clone, ServerMessage::Event { event }).await;
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

    // Task to handle outgoing messages to the client
    let outgoing_task = tokio::spawn(async move {
        while let Ok(msg) = rx.recv().await {
            let json = serde_json::to_string(&msg).unwrap();
            if sender.send(Message::Text(json)).await.is_err() {
                break;
            }
        }
    });

    // Wait for either task to complete (user disconnects or error)
    tokio::select! {
        _ = incoming_task => {},
        _ = outgoing_task => {},
    }

    // Cleanup: Remove user from session
    {
        let mut session = state.write().await;
        session.users.remove(&user_id);
    }

    // Notify others that user left
    broadcast_to_others(&state, &user_id, ServerMessage::UserLeft { user_id: user_id.clone() }).await;
    
    info!("User {} disconnected", user_id);
}

async fn broadcast_to_all(state: &AppState, message: ServerMessage) {
    let session = state.read().await;
    for (_, tx) in &session.users {
        let _ = tx.send(message.clone());
    }
}

async fn broadcast_to_others(state: &AppState, sender_user_id: &str, message: ServerMessage) {
    let session = state.read().await;
    for (user_id, tx) in &session.users {
        if user_id != sender_user_id {
            let _ = tx.send(message.clone());
        }
    }
}