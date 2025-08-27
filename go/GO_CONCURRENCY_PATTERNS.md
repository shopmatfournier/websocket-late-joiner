# Go WebSocket Reliable Event Delivery - Concurrency Patterns

This document showcases how Go's concurrency primitives and idiomatic patterns are used to build a robust, reliable real-time collaboration system.

## Go-Specific Concurrency Features Used

### 1. **Goroutines for Connection Management**

Each WebSocket connection gets dedicated goroutines for reading and writing:

```go
// Per-connection goroutines
connWg.Add(1)
go ss.handleReader(connCtx, userConn, &connWg)  // Reader goroutine

connWg.Add(1) 
go ss.handleWriter(connCtx, userConn, &connWg)  // Writer goroutine

// Background session management goroutines
ss.wg.Add(1)
go ss.eventBroadcaster()  // Event broadcasting goroutine

ss.wg.Add(1)
go ss.userManager()       // User join/leave management

ss.wg.Add(1)
go ss.heartbeatManager()  // Heartbeat and cleanup
```

### 2. **Channels for Event Broadcasting**

Channels provide type-safe, buffered communication between goroutines:

```go
type SessionState struct {
    eventBroadcast  chan BroadcastEvent  // Buffered channel for events
    userJoinLeave   chan UserEvent       // User lifecycle events
    // ...
}

type UserConnection struct {
    SendChan        chan ServerMessage   // Per-user buffered send channel
    ReceiveChan     chan ClientMessage   // Per-user receive channel
    DisconnectChan  chan struct{}        // Disconnect signaling channel
    // ...
}

// Event broadcasting through channels
select {
case ss.eventBroadcast <- BroadcastEvent{
    Event:      event,
    SenderID:   event.UserID,
    AckRequired: true,
}:
case <-ss.ctx.Done():
    return sequence
default:
    log.Printf("Channel full, dropping event %d", sequence)
}
```

### 3. **Select Statements for Non-blocking Operations**

Go's `select` provides elegant handling of multiple channel operations:

```go
// Writer goroutine with select for multiple channels
func (ss *SessionState) handleWriter(ctx context.Context, userConn *UserConnection, wg *sync.WaitGroup) {
    ticker := time.NewTicker(54 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case message := <-userConn.SendChan:
            // Send message to WebSocket
            if err := userConn.Conn.WriteJSON(message); err != nil {
                close(userConn.DisconnectChan)
                return
            }
        case <-ticker.C:
            // Send ping for keep-alive
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
```

### 4. **sync.Map for Concurrent State Management**

Lock-free concurrent maps for high-performance state storage:

```go
type SessionState struct {
    events  sync.Map  // map[uint64]CollaborativeEvent - thread-safe
    users   sync.Map  // map[string]*UserConnection - thread-safe
    // ...
}

// Concurrent event storage
ss.events.Store(sequence, event)

// Concurrent user iteration
ss.users.Range(func(key, value interface{}) bool {
    userConn := value.(*UserConnection)
    // Process each user concurrently
    select {
    case userConn.SendChan <- message:
    default:
        log.Printf("User %s channel full", userConn.UserID)
    }
    return true
})
```

### 5. **Atomic Operations for Lock-Free Counters**

Atomic sequence number generation without locks:

```go
type SessionState struct {
    sequenceCounter uint64  // Accessed atomically
    // ...
}

// Lock-free sequence generation
func (ss *SessionState) NextSequence() uint64 {
    return atomic.AddUint64(&ss.sequenceCounter, 1)
}

func (ss *SessionState) CurrentSequence() uint64 {
    return atomic.LoadUint64(&ss.sequenceCounter)
}
```

### 6. **Context for Cancellation and Timeouts**

Context propagation for graceful shutdown:

```go
func NewSessionState(ctx context.Context) *SessionState {
    sessionCtx, cancel := context.WithCancel(ctx)
    
    ss := &SessionState{
        ctx:    sessionCtx,
        cancel: cancel,
        // ...
    }
    
    // All goroutines respect context cancellation
    go ss.eventBroadcaster()  // Checks <-ss.ctx.Done()
    go ss.userManager()       // Checks <-ss.ctx.Done()
    
    return ss
}

// Per-connection context
connCtx, connCancel := context.WithCancel(ss.ctx)
defer connCancel()
```

### 7. **WaitGroups for Coordinated Shutdown**

Ensures all goroutines complete before shutdown:

```go
type SessionState struct {
    wg sync.WaitGroup  // Coordinate goroutine lifecycle
    // ...
}

// Start goroutines
ss.wg.Add(1)
go ss.eventBroadcaster()

// Graceful shutdown
func (ss *SessionState) Shutdown() {
    ss.cancel()     // Cancel context
    ss.wg.Wait()    // Wait for all goroutines to finish
}
```

## Architecture Comparison

| Feature | Rust | Phoenix | Go |
|---------|------|---------|-----|
| **Concurrency Model** | async/await + Tokio | Actor model (processes) | Goroutines + Channels |
| **State Management** | `Arc<RwLock<T>>` | GenServer | `sync.Map` + atomic |
| **Message Passing** | `broadcast::channel` | Phoenix.PubSub | Go channels |
| **Connection Handling** | Manual split + tasks | Built-in Channel abstraction | Reader/writer goroutines |
| **Synchronization** | Mutexes + atomics | Process isolation | Channels + select |
| **Shutdown** | Manual cleanup | OTP supervision | Context + WaitGroup |
| **Memory Safety** | Compile-time checks | Runtime (BEAM VM) | Compile-time + runtime |

## Performance Characteristics

### Memory Efficiency
- **Goroutines**: ~2KB stack vs OS threads (~8MB)
- **sync.Map**: Lock-free reads, copy-on-write updates
- **Channels**: Bounded buffering prevents memory leaks

### CPU Efficiency  
- **M:N Scheduler**: Goroutines multiplexed onto OS threads
- **Lock-free Atomics**: Sequence generation without contention
- **Channel Operations**: Efficient CSP-style communication

### Scalability
- **10,000+ Goroutines**: Easily handle thousands of connections
- **Channel Buffering**: Configurable backpressure handling
- **Context Cancellation**: Efficient cleanup and resource management

## Idiomatic Go Patterns Demonstrated

### 1. **Channel Direction Enforcement**
```go
func broadcaster(in <-chan Event, out chan<- Result) {
    // in is receive-only, out is send-only
    for event := range in {
        select {
        case out <- process(event):
        case <-time.After(timeout):
            // Handle timeout
        }
    }
}
```

### 2. **Worker Pool Pattern**
```go
// Could be extended with worker pools for event processing
func (ss *SessionState) startWorkerPool(numWorkers int) {
    jobs := make(chan BroadcastEvent, 100)
    
    for i := 0; i < numWorkers; i++ {
        go func() {
            for job := range jobs {
                ss.processEvent(job)
            }
        }()
    }
}
```

### 3. **Fan-out/Fan-in Pattern**
```go
// Event broadcasting is a fan-out pattern
func (ss *SessionState) broadcastToUsers(broadcast BroadcastEvent) {
    ss.users.Range(func(key, value interface{}) bool {
        userConn := value.(*UserConnection)
        
        // Fan-out: send to multiple user channels
        go func(conn *UserConnection) {
            select {
            case conn.SendChan <- message:
            case <-time.After(5 * time.Second):
                log.Printf("Send timeout for user %s", conn.UserID)
            }
        }(userConn)
        
        return true
    })
}
```

### 4. **Heartbeat with Ticker**
```go
func (ss *SessionState) heartbeatManager() {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            ss.sendHeartbeats()
        case <-ss.ctx.Done():
            return
        }
    }
}
```

## Error Handling and Resilience

### 1. **Channel Full Handling**
```go
select {
case userConn.SendChan <- message:
    // Message sent successfully
default:
    // Channel full - log and continue
    log.Printf("User %s send channel full, dropping message", userConn.UserID)
}
```

### 2. **Graceful Connection Cleanup**
```go
defer func() {
    // Cleanup resources
    close(userConn.DisconnectChan)
    
    // Drain channels to prevent goroutine leaks
    go func() {
        for range userConn.SendChan {
            // Drain remaining messages
        }
    }()
}()
```

### 3. **Panic Recovery** (Could be added)
```go
func safeGoroutine(fn func()) {
    go func() {
        defer func() {
            if r := recover(); r != nil {
                log.Printf("Goroutine panic recovered: %v", r)
            }
        }()
        fn()
    }()
}
```

## Testing the Implementation

### Build and Run
```bash
cd go/
go mod tidy
go run main.go
```

### Access Points
- Server: `http://localhost:8080`
- WebSocket endpoint: `ws://localhost:8080/ws`

### Go-Specific Test Scenarios

1. **Channel Backpressure**: Tests buffered channel behavior under load
2. **Goroutine Coordination**: Verifies proper goroutine lifecycle management
3. **Context Cancellation**: Tests graceful shutdown with context
4. **Concurrent Map Operations**: Validates sync.Map performance
5. **Select Statement Behavior**: Tests non-blocking channel operations

## Production Considerations

### Monitoring
```go
// Add metrics collection
var (
    activeConnections = prometheus.NewGauge(prometheus.GaugeOpts{
        Name: "websocket_active_connections",
    })
    eventsProcessed = prometheus.NewCounter(prometheus.CounterOpts{
        Name: "events_processed_total",  
    })
)
```

### Resource Limits
```go
const (
    MaxConnections = 10000
    MaxEventBuffer = 1000
    MaxEventHistory = 100000
)
```

### Health Checks
```go
func healthCheck(w http.ResponseWriter, r *http.Request) {
    stats := map[string]interface{}{
        "active_connections": getActiveConnections(),
        "goroutines": runtime.NumGoroutine(),
        "memory": getMemStats(),
    }
    json.NewEncoder(w).Encode(stats)
}
```

This Go implementation demonstrates how to build reliable, high-performance real-time systems using Go's concurrency primitives, resulting in clean, maintainable code that scales well under load.