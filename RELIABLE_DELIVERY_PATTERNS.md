# Reliable Event Delivery Patterns for Real-Time Collaboration

This document outlines various strategies for handling out-of-order events, missing events, and ensuring reliable delivery in WebSocket-based collaborative applications.

## Problems with Basic Implementation

The original implementation had several reliability issues:

1. **Timestamp-only ordering** - Vulnerable to clock skew and concurrent events
2. **No gap detection** - Missing events go unnoticed
3. **No acknowledgments** - Server doesn't know if clients received events
4. **No retry mechanism** - Lost events are permanently lost
5. **Race conditions** - Events during connection setup can be missed

## Strategy 1: Sequence-Based Ordering with Acknowledgments

### Server-Side Implementation

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollaborativeEvent {
    pub id: String,
    pub user_id: String,
    pub sequence_number: u64,  // ← Global monotonic sequence
    pub timestamp: u64,
    pub event: EventType,
}

pub struct SessionState {
    events: BTreeMap<u64, CollaborativeEvent>, // Ordered by sequence
    sequence_counter: u64,
    users: HashMap<String, UserConnection>,
}

pub struct UserConnection {
    sender: broadcast::Sender<ServerMessage>,
    last_ack_sequence: u64,              // ← Track what user has ACK'd
    pending_events: BTreeMap<u64, CollaborativeEvent>, // ← Events awaiting ACK
}
```

**Key Features:**
- **Monotonic Sequences**: Global counter ensures total ordering
- **Acknowledgment Tracking**: Server knows what each client has received
- **Event Persistence**: Events kept until acknowledged by all clients
- **Gap Detection**: Server can identify missing sequences

### Client-Side Implementation

```javascript
class ReliableWebSocketClient {
    constructor() {
        this.lastReceivedSequence = 0;
        this.eventBuffer = new Map();      // Buffer for out-of-order events
        this.missingSequences = new Set(); // Track gaps
    }
    
    handleEventMessage(event) {
        // Gap detection
        const expectedSeq = this.lastReceivedSequence + 1;
        if (event.sequence_number > expectedSeq) {
            // Mark missing sequences
            for (let seq = expectedSeq; seq < event.sequence_number; seq++) {
                this.missingSequences.add(seq);
            }
            this.requestMissingEvents();
        }
        
        // Buffer out-of-order events
        if (event.sequence_number > this.lastReceivedSequence + 1) {
            this.eventBuffer.set(event.sequence_number, event);
            return;
        }
        
        // Process in-order event
        this.processEvent(event);
        this.processBufferedEvents(); // Try to process buffered events
    }
}
```

## Strategy 2: Vector Clocks for Causal Ordering

For applications requiring causal consistency rather than total ordering:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VectorClock {
    clocks: HashMap<String, u64>, // user_id -> logical clock
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CausalEvent {
    pub id: String,
    pub user_id: String,
    pub vector_clock: VectorClock,
    pub event: EventType,
}

impl VectorClock {
    fn happened_before(&self, other: &VectorClock) -> bool {
        self.clocks.iter().all(|(user, &clock)| {
            other.clocks.get(user).map_or(false, |&other_clock| clock <= other_clock)
        }) && self != other
    }
    
    fn concurrent_with(&self, other: &VectorClock) -> bool {
        !self.happened_before(other) && !other.happened_before(self)
    }
}
```

**Use Cases:**
- Document editing where causal relationships matter
- Systems where total ordering is too restrictive
- Distributed systems with multiple servers

## Strategy 3: Hybrid Approach with Operational Transform

Combines sequence numbers with operational transforms for conflict resolution:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransformableEvent {
    pub sequence_number: u64,
    pub user_id: String,
    pub operation: Operation,
    pub context_vector: Vec<u64>, // Dependencies on other operations
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Operation {
    Insert { position: usize, content: String },
    Delete { position: usize, length: usize },
    Retain { length: usize },
}

impl Operation {
    fn transform_against(&self, other: &Operation) -> (Operation, Operation) {
        // Implement operational transform logic
        match (self, other) {
            (Operation::Insert { position: pos1, content: content1 }, 
             Operation::Insert { position: pos2, content: content2 }) => {
                if pos1 <= pos2 {
                    (self.clone(), Operation::Insert { 
                        position: pos2 + content1.len(), 
                        content: content2.clone() 
                    })
                } else {
                    (Operation::Insert { 
                        position: pos1 + content2.len(), 
                        content: content1.clone() 
                    }, other.clone())
                }
            },
            // ... other transform cases
        }
    }
}
```

## Strategy 4: Event Sourcing with Snapshots

For applications with complex state that need full audit trails:

```rust
pub struct EventStore {
    events: BTreeMap<u64, CollaborativeEvent>,
    snapshots: BTreeMap<u64, DocumentSnapshot>, // sequence -> snapshot
    snapshot_interval: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocumentSnapshot {
    pub sequence_number: u64,
    pub timestamp: u64,
    pub state: serde_json::Value, // Serialized document state
}

impl EventStore {
    fn replay_from_snapshot(&self, snapshot_seq: u64, target_seq: u64) -> Vec<CollaborativeEvent> {
        self.events
            .range(snapshot_seq + 1..=target_seq)
            .map(|(_, event)| event.clone())
            .collect()
    }
    
    fn create_snapshot_if_needed(&mut self, sequence: u64, state: &DocumentState) {
        if sequence % self.snapshot_interval == 0 {
            let snapshot = DocumentSnapshot {
                sequence_number: sequence,
                timestamp: current_timestamp(),
                state: serde_json::to_value(state).unwrap(),
            };
            self.snapshots.insert(sequence, snapshot);
        }
    }
}
```

## Strategy 5: Merkle Trees for Integrity Verification

For applications requiring cryptographic integrity guarantees:

```rust
use sha2::{Digest, Sha256};

#[derive(Debug, Clone)]
pub struct MerkleNode {
    hash: [u8; 32],
    left: Option<Box<MerkleNode>>,
    right: Option<Box<MerkleNode>>,
}

pub struct IntegrityVerifier {
    event_hashes: BTreeMap<u64, [u8; 32]>,
    merkle_roots: BTreeMap<u64, [u8; 32]>, // sequence -> root hash
}

impl IntegrityVerifier {
    fn verify_event_chain(&self, from_seq: u64, to_seq: u64) -> bool {
        // Verify that events form a valid chain
        let mut hasher = Sha256::new();
        for seq in from_seq..=to_seq {
            if let Some(event_hash) = self.event_hashes.get(&seq) {
                hasher.update(event_hash);
            } else {
                return false; // Missing event
            }
        }
        
        let computed_root = hasher.finalize().into();
        self.merkle_roots.get(&to_seq)
            .map_or(false, |&stored_root| computed_root == stored_root)
    }
}
```

## Comparison of Strategies

| Strategy | Ordering | Complexity | Use Case | Performance |
|----------|----------|------------|----------|-------------|
| **Sequence Numbers** | Total | Low | General real-time apps | High |
| **Vector Clocks** | Causal | Medium | Distributed systems | Medium |
| **Operational Transform** | Causal + Conflict Resolution | High | Text editors | Medium |
| **Event Sourcing** | Total + Full History | Medium | Audit requirements | Low |
| **Merkle Trees** | Total + Cryptographic | High | High security | Low |

## Implementation Recommendations

### For Most Applications
Use **Sequence-Based Ordering with Acknowledgments** (Strategy 1):
- Simple to implement and understand
- Good performance characteristics  
- Handles most real-world scenarios
- Easy to debug and monitor

### For Text Editors
Combine **Sequence Numbers + Operational Transform** (Strategy 3):
- Handles concurrent text editing gracefully
- Preserves user intentions
- Well-studied algorithms (e.g., ShareJS, Yjs)

### For High-Security Applications  
Use **Event Sourcing + Merkle Trees** (Strategy 4 + 5):
- Complete audit trail
- Cryptographic integrity verification
- Can detect tampering or corruption
- Supports compliance requirements

### For Distributed Systems
Use **Vector Clocks** (Strategy 2):
- Works across multiple servers
- Preserves causal relationships
- More flexible than total ordering
- Handles network partitions better

## Key Takeaways

1. **Always use sequence numbers** - Timestamps alone are insufficient
2. **Implement acknowledgments** - Know what clients have received
3. **Buffer out-of-order events** - Don't drop events, reorder them
4. **Detect and request missing events** - Implement gap detection
5. **Handle reconnection gracefully** - Resume from last known state
6. **Choose the right strategy** - Based on your consistency requirements

The reliable implementation I provided demonstrates Strategy 1, which covers the majority of real-time collaborative application needs while maintaining good performance and simplicity.