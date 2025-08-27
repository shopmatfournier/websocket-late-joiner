# WebSocket Collaboration Demo - Late Joiner Problem

This Rust + Axum demo demonstrates how real-time collaborative applications handle the late joiner problem.

## Running the Demo

1. **Start the server:**
   ```bash
   cargo run
   ```

2. **Open the test client:**
   Open `client_example.html` in your browser to test the WebSocket connections.

3. **Test the late joiner scenario:**
   - Click "Test Late Joiner Problem" to run an automated test
   - Or manually: Connect User A, send some events, then connect User B

## What This Demo Shows

### The Problem
When User B joins after User A has already sent events, User B needs to receive all historical events to maintain consistency.

### The Solution Implemented
1. **Snapshot + Event Replay:** New users receive all historical events
2. **Synchronization Protocol:** 
   - `sync_start` - Begin sync process
   - `snapshot` - Historical events 
   - `sync_complete` - Ready for real-time updates
3. **Race Condition Handling:** Events sent during connection are captured in the snapshot

### Key Files

- `src/main.rs` - WebSocket server with late joiner handling
- `client_example.html` - Interactive test client
- `late_joiner_problem.md` - Detailed explanation of patterns

### Message Flow

```
User A connects → sends events → User B connects
                      ↓
    Server queues all events in persistent log
                      ↓
User B receives: sync_start → snapshot (all events) → sync_complete
                      ↓
    Both users now receive real-time events
```

The demo includes an artificial 100ms delay during sync to simulate the race condition where events might be missed without proper handling.