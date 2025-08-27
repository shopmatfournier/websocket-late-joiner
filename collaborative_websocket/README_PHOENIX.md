# Phoenix Channels WebSocket Collaboration Demo

This Elixir + Phoenix implementation demonstrates how real-time collaborative applications handle the late joiner problem using Phoenix Channels.

## Architecture

### Key Components

1. **SessionChannel** (`lib/collaborative_websocket_web/channels/session_channel.ex`)
   - Handles WebSocket connections and message routing
   - Implements the late joiner synchronization protocol
   - Manages user join/leave notifications

2. **SessionState** (`lib/collaborative_websocket/session_state.ex`)
   - GenServer that maintains session state and event history
   - Stores up to 1000 events with automatic cleanup
   - Provides events filtering by timestamp for late joiners

3. **UserSocket** (`lib/collaborative_websocket_web/channels/user_socket.ex`)
   - Socket handler that routes channel connections
   - Maps `session:*` topics to SessionChannel

### Late Joiner Synchronization Protocol

When a user joins the session:
1. **sync_start** - Indicates synchronization has begun
2. **snapshot** - Sends all historical events since last known version
3. **sync_complete** - Marks synchronization as finished and real-time updates begin

During synchronization, a 100ms delay is added to simulate processing time and demonstrate race condition handling.

## Running the Demo

1. **Start the server:**
   ```bash
   cd collaborative_websocket
   mix phx.server
   ```

2. **Open your browser:**
   Navigate to `http://localhost:4000` to access the test interface

3. **Test the late joiner scenario:**
   - Click "Test Late Joiner Problem" for automated testing
   - Or manually: Connect User A → Send events → Connect User B

## Event Types Supported

- **Draw Events**: Line drawings with coordinates and color
- **Circle Events**: Circles with center, radius, and color  
- **Move Events**: Object movement with new position
- **Delete Events**: Object deletion by ID

## Implementation Highlights

### Phoenix Channel Benefits
- **Automatic Reconnection**: Built-in connection resilience
- **Message Guarantees**: At-least-once delivery semantics
- **Scalability**: Distributed across multiple nodes with Phoenix.PubSub
- **Process Isolation**: Each channel runs in its own process

### State Management
- **GenServer-based**: Leverages OTP supervision for fault tolerance
- **Memory Efficient**: Automatic event history trimming
- **Concurrent Access**: Thread-safe state operations
- **Version Tracking**: Timestamp-based event ordering

### Race Condition Handling
- **Event Buffering**: All events stored persistently during user sync
- **Atomic Synchronization**: Complete snapshot delivery before real-time updates
- **Order Preservation**: Events delivered in chronological order

## Comparison with Rust Implementation

| Aspect | Rust + Axum | Elixir + Phoenix |
|--------|-------------|------------------|
| **Concurrency** | Tokio async/await | Actor model (processes) |
| **State Management** | Arc<RwLock<T>> | GenServer |
| **Connection Handling** | Manual WebSocket splitting | Built-in Channel abstraction |
| **Broadcasting** | Manual user tracking | Phoenix.PubSub |
| **Fault Tolerance** | Manual error handling | OTP supervision trees |
| **Scalability** | Single-node | Multi-node clustering |

## Key Files

- `lib/collaborative_websocket_web/channels/session_channel.ex` - Main channel logic
- `lib/collaborative_websocket/session_state.ex` - State management GenServer  
- `lib/collaborative_websocket_web/controllers/page_html/home.html.heex` - Test client UI
- `assets/js/app.js` - Phoenix Socket configuration

This implementation showcases Elixir's strengths in building fault-tolerant, distributed real-time systems with minimal code complexity.