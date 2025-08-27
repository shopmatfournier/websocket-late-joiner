package main

import (
	"context"
	"log"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
)

// Event types and structures
type EventType string

const (
	EventTypeDraw   EventType = "draw"
	EventTypeCircle EventType = "circle"
	EventTypeMove   EventType = "move"
	EventTypeDelete EventType = "delete"
)

type CollaborativeEvent struct {
	ID             string                 `json:"id"`
	UserID         string                 `json:"user_id"`
	SequenceNumber uint64                 `json:"sequence_number"`
	Timestamp      int64                  `json:"timestamp"`
	Event          map[string]interface{} `json:"event"`
}

type ServerMessage struct {
	Type    string      `json:"type"`
	Payload interface{} `json:"payload,omitempty"`
}

type ClientMessage struct {
	Type    string                 `json:"type"`
	Payload map[string]interface{} `json:"payload,omitempty"`
}

// User connection representing each WebSocket client
type UserConnection struct {
	ID                string
	UserID            string
	Conn              *websocket.Conn
	SendChan          chan ServerMessage     // Buffered channel for outgoing messages
	ReceiveChan       chan ClientMessage     // Channel for incoming messages
	LastAckSequence   uint64                 // Last acknowledged sequence number
	PendingEvents     map[uint64]CollaborativeEvent // Events waiting for ACK
	LastHeartbeat     time.Time
	DisconnectChan    chan struct{}          // Signal for disconnection
	mu                sync.RWMutex           // Protect concurrent access
}

// Session state with Go concurrency patterns
type SessionState struct {
	events            sync.Map            // map[uint64]CollaborativeEvent - concurrent map
	sequenceCounter   uint64              // atomic counter for sequences
	users             sync.Map            // map[string]*UserConnection - concurrent user map
	eventBroadcast    chan BroadcastEvent // Channel for broadcasting events
	userJoinLeave     chan UserEvent      // Channel for user join/leave events
	heartbeatTicker   *time.Ticker        // Heartbeat ticker
	cleanupTicker     *time.Ticker        // Cleanup ticker
	ctx               context.Context
	cancel            context.CancelFunc
	wg                sync.WaitGroup       // Wait group for graceful shutdown
}

type BroadcastEvent struct {
	Event      CollaborativeEvent
	SenderID   string
	AckRequired bool
}

type UserEvent struct {
	Type   string // "join" or "leave"
	UserID string
	Conn   *UserConnection
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		return true // Allow connections from any origin
	},
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
}

// NewSessionState creates a new session state with Go concurrency patterns
func NewSessionState(ctx context.Context) *SessionState {
	sessionCtx, cancel := context.WithCancel(ctx)
	
	ss := &SessionState{
		eventBroadcast:  make(chan BroadcastEvent, 1000),
		userJoinLeave:   make(chan UserEvent, 100),
		heartbeatTicker: time.NewTicker(30 * time.Second),
		cleanupTicker:   time.NewTicker(60 * time.Second),
		ctx:             sessionCtx,
		cancel:          cancel,
	}
	
	// Start background goroutines for session management
	ss.wg.Add(1)
	go ss.eventBroadcaster()
	
	ss.wg.Add(1)
	go ss.userManager()
	
	ss.wg.Add(1)
	go ss.heartbeatManager()
	
	return ss
}

// Get next sequence number atomically
func (ss *SessionState) NextSequence() uint64 {
	return atomic.AddUint64(&ss.sequenceCounter, 1)
}

// Get current sequence number
func (ss *SessionState) CurrentSequence() uint64 {
	return atomic.LoadUint64(&ss.sequenceCounter)
}

// Add event with automatic sequencing
func (ss *SessionState) AddEvent(event CollaborativeEvent) uint64 {
	sequence := ss.NextSequence()
	event.SequenceNumber = sequence
	event.Timestamp = time.Now().UnixMilli()
	event.ID = uuid.New().String()
	
	// Store in concurrent map
	ss.events.Store(sequence, event)
	
	// Broadcast through channel
	select {
	case ss.eventBroadcast <- BroadcastEvent{
		Event:      event,
		SenderID:   event.UserID,
		AckRequired: true,
	}:
	case <-ss.ctx.Done():
		return sequence
	default:
		log.Printf("Event broadcast channel full, dropping event %d", sequence)
	}
	
	return sequence
}

// Get events since a sequence number
func (ss *SessionState) GetEventsSince(lastSequence uint64) []CollaborativeEvent {
	var events []CollaborativeEvent
	
	ss.events.Range(func(key, value interface{}) bool {
		seq := key.(uint64)
		if seq > lastSequence {
			events = append(events, value.(CollaborativeEvent))
		}
		return true
	})
	
	// Sort by sequence number (Go's sort would be more efficient for large datasets)
	for i := 0; i < len(events)-1; i++ {
		for j := i + 1; j < len(events); j++ {
			if events[i].SequenceNumber > events[j].SequenceNumber {
				events[i], events[j] = events[j], events[i]
			}
		}
	}
	
	return events
}

// Get specific events by sequence numbers
func (ss *SessionState) GetEventsBySequences(sequences []uint64) []CollaborativeEvent {
	var events []CollaborativeEvent
	
	for _, seq := range sequences {
		if event, exists := ss.events.Load(seq); exists {
			events = append(events, event.(CollaborativeEvent))
		}
	}
	
	return events
}

// Event broadcaster goroutine - idiomatic Go pattern
func (ss *SessionState) eventBroadcaster() {
	defer ss.wg.Done()
	
	for {
		select {
		case broadcast := <-ss.eventBroadcast:
			ss.broadcastToUsers(broadcast)
		case <-ss.ctx.Done():
			return
		}
	}
}

// User manager goroutine
func (ss *SessionState) userManager() {
	defer ss.wg.Done()
	
	for {
		select {
		case userEvent := <-ss.userJoinLeave:
			switch userEvent.Type {
			case "join":
				ss.handleUserJoin(userEvent)
			case "leave":
				ss.handleUserLeave(userEvent)
			}
		case <-ss.ctx.Done():
			return
		}
	}
}

// Heartbeat manager goroutine
func (ss *SessionState) heartbeatManager() {
	defer ss.wg.Done()
	
	for {
		select {
		case <-ss.heartbeatTicker.C:
			ss.sendHeartbeats()
		case <-ss.cleanupTicker.C:
			ss.cleanupExpiredUsers()
		case <-ss.ctx.Done():
			return
		}
	}
}

func (ss *SessionState) broadcastToUsers(broadcast BroadcastEvent) {
	message := ServerMessage{
		Type: "event",
		Payload: map[string]interface{}{
			"event":        broadcast.Event,
			"ack_required": broadcast.AckRequired,
		},
	}
	
	ss.users.Range(func(key, value interface{}) bool {
		userConn := value.(*UserConnection)
		
		// Don't send to sender
		if userConn.UserID == broadcast.SenderID {
			return true
		}
		
		// Add to pending events if ACK required
		if broadcast.AckRequired {
			userConn.mu.Lock()
			userConn.PendingEvents[broadcast.Event.SequenceNumber] = broadcast.Event
			userConn.mu.Unlock()
		}
		
		// Send through user's channel (non-blocking)
		select {
		case userConn.SendChan <- message:
		default:
			log.Printf("User %s send channel full, dropping message", userConn.UserID)
		}
		
		return true
	})
}

func (ss *SessionState) handleUserJoin(event UserEvent) {
	// Broadcast user joined
	joinMessage := ServerMessage{
		Type: "user_joined",
		Payload: map[string]interface{}{
			"user_id": event.UserID,
		},
	}
	
	ss.users.Range(func(key, value interface{}) bool {
		userConn := value.(*UserConnection)
		if userConn.UserID != event.UserID {
			select {
			case userConn.SendChan <- joinMessage:
			default:
			}
		}
		return true
	})
}

func (ss *SessionState) handleUserLeave(event UserEvent) {
	// Remove user
	ss.users.Delete(event.UserID)
	
	// Broadcast user left
	leaveMessage := ServerMessage{
		Type: "user_left",
		Payload: map[string]interface{}{
			"user_id": event.UserID,
		},
	}
	
	ss.users.Range(func(key, value interface{}) bool {
		userConn := value.(*UserConnection)
		select {
		case userConn.SendChan <- leaveMessage:
		default:
		}
		return true
	})
}

func (ss *SessionState) sendHeartbeats() {
	currentSeq := ss.CurrentSequence()
	heartbeatMsg := ServerMessage{
		Type: "heartbeat",
		Payload: map[string]interface{}{
			"sequence":  currentSeq,
			"timestamp": time.Now().UnixMilli(),
		},
	}
	
	ss.users.Range(func(key, value interface{}) bool {
		userConn := value.(*UserConnection)
		select {
		case userConn.SendChan <- heartbeatMsg:
		default:
		}
		return true
	})
}

func (ss *SessionState) cleanupExpiredUsers() {
	timeout := 90 * time.Second
	now := time.Now()
	
	var expiredUsers []string
	
	ss.users.Range(func(key, value interface{}) bool {
		userConn := value.(*UserConnection)
		userConn.mu.RLock()
		expired := now.Sub(userConn.LastHeartbeat) > timeout
		userConn.mu.RUnlock()
		
		if expired {
			expiredUsers = append(expiredUsers, userConn.UserID)
		}
		return true
	})
	
	// Clean up expired users
	for _, userID := range expiredUsers {
		if conn, exists := ss.users.Load(userID); exists {
			userConn := conn.(*UserConnection)
			close(userConn.DisconnectChan)
			
			// Send leave event
			select {
			case ss.userJoinLeave <- UserEvent{
				Type:   "leave",
				UserID: userID,
			}:
			default:
			}
		}
	}
}

// Acknowledge event for user
func (ss *SessionState) AcknowledgeEvent(userID string, sequenceNumber uint64) {
	if conn, exists := ss.users.Load(userID); exists {
		userConn := conn.(*UserConnection)
		userConn.mu.Lock()
		userConn.LastAckSequence = max(userConn.LastAckSequence, sequenceNumber)
		delete(userConn.PendingEvents, sequenceNumber)
		userConn.mu.Unlock()
	}
}

// Graceful shutdown
func (ss *SessionState) Shutdown() {
	ss.heartbeatTicker.Stop()
	ss.cleanupTicker.Stop()
	ss.cancel()
	ss.wg.Wait()
}

// WebSocket handler
func (ss *SessionState) HandleWebSocket(w http.ResponseWriter, r *http.Request) {
	// Get user parameters
	userID := r.URL.Query().Get("user_id")
	lastKnownSeq := r.URL.Query().Get("last_known_sequence")
	
	if userID == "" {
		http.Error(w, "user_id required", http.StatusBadRequest)
		return
	}
	
	lastSeq := uint64(0)
	if lastKnownSeq != "" {
		if parsed, err := strconv.ParseUint(lastKnownSeq, 10, 64); err == nil {
			lastSeq = parsed
		}
	}
	
	// Upgrade connection
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade failed: %v", err)
		return
	}
	defer conn.Close()
	
	// Create user connection
	userConn := &UserConnection{
		ID:              uuid.New().String(),
		UserID:          userID,
		Conn:            conn,
		SendChan:        make(chan ServerMessage, 1000),
		ReceiveChan:     make(chan ClientMessage, 100),
		PendingEvents:   make(map[uint64]CollaborativeEvent),
		LastHeartbeat:   time.Now(),
		DisconnectChan:  make(chan struct{}),
	}
	
	// Add user to session
	ss.users.Store(userID, userConn)
	
	// Create context for this connection
	connCtx, connCancel := context.WithCancel(ss.ctx)
	defer connCancel()
	
	// Start goroutines for this connection
	var connWg sync.WaitGroup
	
	// Reader goroutine
	connWg.Add(1)
	go ss.handleReader(connCtx, userConn, &connWg)
	
	// Writer goroutine
	connWg.Add(1)
	go ss.handleWriter(connCtx, userConn, &connWg)
	
	// Send initial synchronization
	ss.sendSynchronization(userConn, lastSeq)
	
	// Notify about user join
	select {
	case ss.userJoinLeave <- UserEvent{
		Type:   "join",
		UserID: userID,
		Conn:   userConn,
	}:
	default:
	}
	
	log.Printf("User %s connected", userID)
	
	// Wait for disconnection
	select {
	case <-userConn.DisconnectChan:
	case <-connCtx.Done():
	}
	
	// Cleanup
	connCancel()
	connWg.Wait()
	
	// Notify about user leave
	select {
	case ss.userJoinLeave <- UserEvent{
		Type:   "leave",
		UserID: userID,
	}:
	default:
	}
	
	log.Printf("User %s disconnected", userID)
}

// Send initial synchronization to user
func (ss *SessionState) sendSynchronization(userConn *UserConnection, lastSeq uint64) {
	// Send sync start
	syncID := uuid.New().String()
	syncStart := ServerMessage{
		Type: "sync_start",
		Payload: map[string]interface{}{
			"sync_id": syncID,
		},
	}
	
	select {
	case userConn.SendChan <- syncStart:
	default:
	}
	
	// Get events since last sequence
	events := ss.GetEventsSince(lastSeq)
	currentSeq := ss.CurrentSequence()
	
	// Send snapshot if needed
	if len(events) > 0 {
		snapshot := ServerMessage{
			Type: "snapshot",
			Payload: map[string]interface{}{
				"events":        events,
				"last_sequence": currentSeq,
			},
		}
		
		select {
		case userConn.SendChan <- snapshot:
		default:
		}
		
		// Simulate processing delay
		time.Sleep(100 * time.Millisecond)
	}
	
	// Send sync complete
	syncComplete := ServerMessage{
		Type: "sync_complete",
		Payload: map[string]interface{}{
			"current_sequence": currentSeq,
		},
	}
	
	select {
	case userConn.SendChan <- syncComplete:
	default:
	}
}

// Reader goroutine for handling incoming messages
func (ss *SessionState) handleReader(ctx context.Context, userConn *UserConnection, wg *sync.WaitGroup) {
	defer wg.Done()
	
	// Set read deadline and ping handler
	userConn.Conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	userConn.Conn.SetPongHandler(func(string) error {
		userConn.Conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		userConn.mu.Lock()
		userConn.LastHeartbeat = time.Now()
		userConn.mu.Unlock()
		return nil
	})
	
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		
		var msg ClientMessage
		if err := userConn.Conn.ReadJSON(&msg); err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("WebSocket error for user %s: %v", userConn.UserID, err)
			}
			close(userConn.DisconnectChan)
			return
		}
		
		// Process message based on type
		ss.handleClientMessage(userConn, msg)
	}
}

// Writer goroutine for handling outgoing messages
func (ss *SessionState) handleWriter(ctx context.Context, userConn *UserConnection, wg *sync.WaitGroup) {
	defer wg.Done()
	
	// Ping ticker for keep-alive
	ticker := time.NewTicker(54 * time.Second)
	defer ticker.Stop()
	
	for {
		select {
		case message := <-userConn.SendChan:
			userConn.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := userConn.Conn.WriteJSON(message); err != nil {
				log.Printf("Write error for user %s: %v", userConn.UserID, err)
				close(userConn.DisconnectChan)
				return
			}
		case <-ticker.C:
			userConn.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := userConn.Conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				close(userConn.DisconnectChan)
				return
			}
		case <-ctx.Done():
			return
		case <-userConn.DisconnectChan:
			return
		}
	}
}

// Handle client messages
func (ss *SessionState) handleClientMessage(userConn *UserConnection, msg ClientMessage) {
	switch msg.Type {
	case "ack":
		if seqInterface, exists := msg.Payload["sequence_number"]; exists {
			if seq, ok := seqInterface.(float64); ok {
				ss.AcknowledgeEvent(userConn.UserID, uint64(seq))
			}
		}
		
	case "gap_report":
		if missingInterface, exists := msg.Payload["missing_sequences"]; exists {
			if missingSlice, ok := missingInterface.([]interface{}); ok {
				var sequences []uint64
				for _, seqInterface := range missingSlice {
					if seq, ok := seqInterface.(float64); ok {
						sequences = append(sequences, uint64(seq))
					}
				}
				
				// Get missing events and send them back
				events := ss.GetEventsBySequences(sequences)
				if len(events) > 0 {
					resendMsg := ServerMessage{
						Type: "resend_events",
						Payload: map[string]interface{}{
							"events": events,
							"reason": "gap_recovery",
						},
					}
					
					select {
					case userConn.SendChan <- resendMsg:
					default:
					}
				}
			}
		}
		
	case "heartbeat_response":
		userConn.mu.Lock()
		userConn.LastHeartbeat = time.Now()
		userConn.mu.Unlock()
		
	case string(EventTypeDraw), string(EventTypeCircle), string(EventTypeMove), string(EventTypeDelete):
		// Handle event creation
		event := CollaborativeEvent{
			UserID: userConn.UserID,
			Event:  msg.Payload,
		}
		event.Event["type"] = msg.Type
		
		ss.AddEvent(event)
	}
}

// Serve static files
func serveHome(w http.ResponseWriter, r *http.Request) {
	http.ServeFile(w, r, "client.html")
}

// Helper function for max
func max(a, b uint64) uint64 {
	if a > b {
		return a
	}
	return b
}

func main() {
	ctx := context.Background()
	sessionState := NewSessionState(ctx)
	defer sessionState.Shutdown()
	
	// Routes
	http.HandleFunc("/", serveHome)
	http.HandleFunc("/ws", sessionState.HandleWebSocket)
	
	log.Println("Go WebSocket server starting on :8080")
	log.Println("Open http://localhost:8080 to test")
	
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatal("Server failed:", err)
	}
}