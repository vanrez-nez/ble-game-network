# BLE Game Network Protocol Specification

**Version:** 1.0
**Status:** Draft

---

## 1. Glossary

| Term | Definition |
|------|-----------|
| **Host** | The device running the GATT Server, advertising the Room, and relaying packets between Clients. |
| **Client** | A device connected to a Host via GATT Client role. Sends writes, receives notifications. |
| **Peer** | Any participant in a Session (Host or Client). Identified by a Peer ID. |
| **Peer ID** | A 6-character hexadecimal string derived from a random UUID. Unique per app launch. |
| **Session** | An active game room with one Host and zero or more Clients. Identified by a Session ID. |
| **Session ID** | A 6-character hexadecimal string generated when a Host starts. |
| **Room** | The advertised description of a Session, discoverable via BLE scan. |
| **Room ID** | The BLE device address or peripheral identifier of the Host. |
| **Packet** | A versioned binary envelope containing kind, addressing, message type, and payload. |
| **Fragment** | A BLE-sized chunk of a Packet, with a 5-byte header for reassembly. |
| **Nonce** | A 16-bit unsigned counter identifying a set of Fragments belonging to one Packet. |
| **Transport** | The reliability mode: *Reliable* (no recovery) or *Resilient* (auto-migration). |
| **Migration** | The transfer of Host role to a successor Peer when the current Host leaves or is lost. |
| **Reconnect Grace** | A 10-second window during which a disconnected Peer may rejoin without being removed from the Session. |
| **HELLO** | A control Packet sent by a Client to a Host to complete the join handshake. |
| **Roster** | The set of Peer IDs currently participating in a Session. |
| **Heartbeat** | A periodic re-broadcast of the last broadcast Packet from Host to all Clients. |
| **Dedup** | Duplicate detection based on (Peer ID, message type, Nonce) tuples with time-based expiry. |
| **Codec** | The binary serialization format for application payloads (Lua values to bytes). |
| **CCCD** | Client Characteristic Configuration Descriptor — the standard BLE descriptor for enabling notifications. |

---

## 2. GATT Service Definition

The protocol uses a single GATT Service with a single Characteristic.

| Component | UUID |
|-----------|------|
| Service | `4bdf6b6d-6b77-4b3f-9f4a-5a2d1499d641` |
| Message Characteristic | `9e153f71-c2d0-4ee1-8b8d-090421bea607` |
| CCCD | `00002902-0000-1000-8000-00805f9b34fb` |

**Characteristic properties:** Read, Write, Notify.

- **Clients write** Fragments to this Characteristic (Client → Host).
- **Host notifies** Fragments via this Characteristic (Host → Client).

---

## 3. Room Advertisement

### 3.1 Encoding

A Room is encoded as a UTF-8 string with the following layout:

```
Offset  Length  Field
0       3       Prefix          "LB1" (literal)
3       6       SessionID       6-char hex
9       6       HostPeerID      6-char hex
15      1       Transport       'r' = Reliable, 's' = Resilient
16      1       MaxClients      ASCII digit '1'-'7'
17      1       PeerCount       ASCII digit '0'-'9'
18      0-8     RoomName        UTF-8, variable length
```

Total: 18–26 bytes.

### 3.2 Room Name Normalization

**NormalizeRoomName(name)**
1. If *name* is empty or null, return `"Room"`.
2. Replace all pipe characters (`|`), newline (`\n`), and carriage return (`\r`) with space.
3. Trim leading and trailing whitespace.
4. If result is empty, return `"Room"`.
5. If result length exceeds 8, truncate to first 8 characters.
6. Return result.

### 3.3 Advertising

**AdvertiseRoom()**
1. Let *payload* be the result of encoding the Room per Section 3.1.
2. On Android: set *payload* as Manufacturer Specific Data with company ID `0xFFFF` in the Scan Response. Set Service UUID in the Advertising Data.
3. On iOS: set *payload* as the Local Name field in the Advertisement Data.
4. Set advertise mode to Low Latency, connectable, no timeout.

### 3.4 Discovery

**DecodeRoom(advertisementData)**
1. Attempt to extract Manufacturer Data with company ID `0xFFFF`. If present and starts with `"LB1"`, decode per Section 3.1 and return Room.
2. Attempt to extract Service Data for the Service UUID. If present and starts with `"LB1"`, decode per Section 3.1 and return Room.
3. Attempt to read the Local Name. If it starts with `"LB1"`, decode per Section 3.1 and return Room.
4. Return null (not a recognized Room).

### 3.5 Room Expiry

Discovered Rooms that have not been seen for 4 seconds are considered lost. On Android this is handled by `CALLBACK_TYPE_MATCH_LOST`. On iOS a periodic timer checks `lastSeenAt`.

---

## 4. Packet Format

### 4.1 Packet Envelope

All data is big-endian.

```
Offset  Size    Field
0       1       Version         Must be 1
1       4       KindLength      Length of Kind string
5       N       Kind            UTF-8 string: "data" or "control"
5+N     4       FromLength      Length of FromPeerID string
9+N     M       FromPeerID      UTF-8 string (6 chars for peers, may be empty)
9+N+M   4       ToLength        Length of ToPeerID string
13+N+M  P       ToPeerID        UTF-8 string (empty = broadcast, 6 chars = directed)
13+N+M+P 4      TypeLength      Length of MsgType string
17+N+M+P Q      MsgType         UTF-8 string (e.g. "hello", "ping", "chat")
17+N+M+P+Q 4    PayloadLength   Length of payload bytes
21+N+M+P+Q R    Payload         Raw binary bytes (Codec-encoded for data, raw for control)
```

**Constraints:**
- String lengths must not exceed 4096 bytes.
- Payload length must not exceed 65536 bytes.
- Version mismatch causes the Packet to be silently dropped.

### 4.2 Packet Kinds

| Kind | Purpose |
|------|---------|
| `"data"` | Application message. Payload is Codec-encoded (Section 8). Subject to Dedup. |
| `"control"` | Protocol control message. Payload format depends on MsgType. Not subject to Dedup. |

### 4.3 Control Message Types

| MsgType | Direction | Payload | Purpose |
|---------|-----------|---------|---------|
| `"hello"` | Client → Host | Empty | Join handshake initiation |
| `"peer_joined"` | Host → Client | Empty | Notify that a Peer entered the Session |
| `"peer_left"` | Host → Client | UTF-8 reason string | Notify that a Peer left the Session |
| `"session_migrating"` | Host → Client | Migration payload (Section 6.2) | Host is transferring role |
| `"session_ended"` | Host → Client | UTF-8 reason string | Session has been terminated |

---

## 5. Fragmentation

### 5.1 Fragment Header

Every Fragment has a fixed 5-byte header followed by a payload chunk.

```
Offset  Size  Field
0       1     Version       Must be 1
1       1     NonceHigh     Upper 8 bits of 16-bit Nonce
2       1     NonceLow      Lower 8 bits of 16-bit Nonce
3       1     Index         0-based fragment index (0–254)
4       1     Count         Total fragment count (1–255)
5       N     Chunk         Payload bytes for this fragment
```

### 5.2 Fragmenting a Packet

**FragmentPacket(packetBytes, payloadLimit)**
1. Let *chunkSize* = *payloadLimit* - 5.
2. If *chunkSize* <= 0, emit error `"send_failed"` and return null.
3. Let *fragmentCount* = ceil(len(*packetBytes*) / *chunkSize*).
4. If *fragmentCount* > 255, emit error `"payload_too_large"` and return null.
5. Let *nonce* = NextNonce().
6. For each *index* from 0 to *fragmentCount* - 1:
   a. Let *start* = *index* * *chunkSize*.
   b. Let *end* = min(*start* + *chunkSize*, len(*packetBytes*)).
   c. Let *chunk* = *packetBytes*[*start* .. *end*].
   d. Construct Fragment: `[1, nonceHigh, nonceLow, index, fragmentCount] ++ chunk`.
7. Return list of Fragments.

### 5.3 NextNonce

**NextNonce()**
1. Increment the 16-bit nonce counter.
2. If counter equals 0, set counter to 1 (nonce 0 is reserved).
3. Return counter value.

### 5.4 Reassembling Fragments

**ProcessIncomingFragment(sourceKey, fragmentData)**
1. Parse the 5-byte header. If version != 1, drop silently.
2. Extract *nonce*, *index*, *count* from header.
3. If *count* == 1, return Fragment payload immediately (single-fragment fast path).
4. Let *assemblyKey* = sourceKey + ":" + nonce.
5. Look up or create an InboundAssembly for *assemblyKey*.
6. If creating new: initialize with *count* slots, set `updatedAt` to now.
7. If existing and *count* differs from stored count, discard assembly and return null.
8. If slot at *index* is already filled:
   a. If data matches, ignore (benign duplicate).
   b. If data differs, discard entire assembly and return null (conflict).
9. Store chunk at slot *index*. Increment `receivedCount`. Add chunk length to `totalBytes`. Update `updatedAt`.
10. If `receivedCount` < `count`, return null (incomplete).
11. Concatenate all slots in index order into a single byte array.
12. Remove assembly from tracking.
13. If total length exceeds 65536 bytes, emit error and return null.
14. Return reassembled bytes and *nonce*.

### 5.5 Assembly Timeout

Assemblies older than 15 seconds (since last `updatedAt`) are discarded. Checked on each incoming fragment.

---

## 6. Connection Lifecycle

### 6.1 Hosting a Session

**Host(roomName, maxClients, transport)**
1. Assert BLE is available and permissions granted.
2. Call Leave() to clean up any existing session.
3. Let *sessionId* = GenerateShortID().
4. Let *roomName* = NormalizeRoomName(*roomName*).
5. Clamp *maxClients* to range [1, 7].
6. Open a GATT Server.
7. Create the Service with the Message Characteristic (Read, Write, Notify) and CCCD.
8. Add Service to GATT Server.
9. On service added successfully:
   a. Call AdvertiseRoom().
   b. Start Heartbeat timer.
   c. Emit `hosted` event with *sessionId*, local Peer ID, and *transport*.

### 6.2 Scanning for Rooms

**Scan()**
1. Assert BLE is available and permissions granted.
2. Stop any existing scan.
3. Clear discovered rooms.
4. Start BLE scan with Low Latency mode, no service filter.
5. On each scan result: call DecodeRoom(). If valid, store in rooms map. If not in active Migration or Reconnect, emit `room_found` event.
6. On room lost: emit `room_lost` event.

### 6.3 Joining a Room

**Join(roomID)**
1. Assert BLE is available and permissions granted.
2. Look up Room by *roomID* in discovered rooms.
3. If not found, emit error `"room_gone"`.
4. Call ConnectToRoom(room, migrationJoin=false).

**ConnectToRoom(room, migrationJoin)**
1. If already connected to the same room/session/host and not leaving, return (duplicate join guard).
2. Stop scan. Call StopClientOnly() to clean up prior connection.
3. Store session info: *joinedRoomId*, *joinedSessionId*, *hostPeerId*, *transport*, *maxClients*.
4. Set `clientLeaving` = false, `clientJoined` = false.
5. If not *migrationJoin* and not reconnect join, reset Session Peer roster.
6. Connect to the Room's BLE device via GATT Client with `autoConnect=false`.
7. On GATT connected:
   a. Request MTU (desired: 185, minimum: 23).
   b. Discover services.
   c. Find Message Characteristic.
   d. Enable notifications via CCCD descriptor write.
   e. Call CompleteLocalJoin().

### 6.4 CompleteLocalJoin

**CompleteLocalJoin()**
1. Set `clientJoined` = true.
2. Add local Peer ID and Host Peer ID to Session Peer roster.
3. If reconnect is in progress, call CompleteReconnectResume() and go to step 5.
4. Else if migration join is in progress, call CompleteMigrationResume() and go to step 5.
5. Else emit `joined` event with session info.
6. Encode and enqueue a HELLO control Packet (from=localPeerID, to=hostPeerID, type="hello", payload=empty).

### 6.5 HELLO Handshake (Host Side)

**OnHelloReceived(sourceDeviceKey, packet)**
1. Let *peerId* = packet.fromPeerId. If empty, reject.
2. Remove device from pending clients.
3. Bind: map *sourceDeviceKey* → *peerId* in device-peer map.
4. Bind: map *peerId* → device in connected clients.
5. Add *peerId* to Session Peer roster.
6. If *peerId* is in Reconnect Grace:
   a. Cancel the grace timer for *peerId*.
   b. Emit `peer_status` event with status `"connected"`.
   c. Send Roster to the reconnected Client.
7. Else (new peer):
   a. Send Roster to the new Client (one `peer_joined` control per existing Peer).
   b. Emit `peer_joined` event.
   c. Broadcast `peer_joined` control to all other Clients.
8. Update advertisement (peer count changed).

### 6.6 Leaving a Session

**Leave()**
1. If hosting with Resilient transport and clients exist, attempt BeginGracefulMigration(). If successful, return.
2. Call FinishLeave(reason=null for client, "host_left" for host).

**FinishLeave(remoteReason)**
1. Cancel all timers (migration, reconnect, heartbeat, grace periods).
2. Clear reconnect state fields.
3. Clear dedup state.
4. If *remoteReason* is not null, send `session_ended` control to all Clients.
5. Stop advertising. Stop scanning.
6. Set `hosting` = false, `clientLeaving` = true.
7. Close GATT Server. Close GATT Client.
8. Clear all maps (rooms, clients, peers, queues, assemblies).
9. Reset session identifiers and flags.

---

## 7. Reconnection

### 7.1 Client Reconnect

Triggered when the Client's BLE connection to the Host drops unexpectedly (after a successful join, not during intentional leave or migration).

**BeginClientReconnect()**
1. If *joinedSessionId* or *hostPeerId* is empty, return false.
2. Save *joinedSessionId* and *hostPeerId* into reconnect fields.
3. Emit `peer_status` event for local Peer with status `"reconnecting"`.
4. Schedule a Reconnect Timeout (default 10 seconds).
5. Start a BLE scan.
6. Set `reconnectScanInProgress` = true.
7. Return true.

**OnScanResultDuringReconnect(room)**
1. If room matches saved session/host IDs:
   a. Set `reconnectJoinInProgress` = true.
   b. Call ConnectToRoom(room, migrationJoin=false).
2. Else if room has the same host Peer ID but different Session ID (host restarted):
   a. Call FailReconnect().
3. Else: ignore (still scanning).

**CompleteReconnectResume()**
1. Cancel Reconnect Timeout.
2. Clear all reconnect state fields.
3. Emit `peer_status` event for local Peer with status `"connected"`.

**FailReconnect()**
1. Cancel Reconnect Timeout.
2. Clear all reconnect state fields.
3. Stop scan.
4. Call FinishLeave(null).
5. Emit `session_ended` event with reason `"host_lost"`.

**OnReconnectTimeout()**
1. Call FailReconnect().

### 7.2 Host Reconnect Grace

Triggered when a Client's BLE connection drops on the Host side.

**BeginPeerReconnectGrace(peerId)**
1. Remove *peerId* from connected clients map (device handle is dead).
2. Do NOT remove *peerId* from Session Peer roster.
3. Do NOT notify other Clients of departure.
4. Emit `peer_status` event for *peerId* with status `"reconnecting"`.
5. Schedule a per-peer Grace Timeout (default 10 seconds).
6. Update advertisement (available slot opened).

**OnGraceTimeout(peerId)**
1. Remove *peerId* from Session Peer roster.
2. Emit `peer_left` event with reason `"timeout"`.
3. Send `peer_left` control to all remaining Clients.
4. Update advertisement.

**OnReconnectHello(peerId)**
1. Cancel the Grace Timeout for *peerId*.
2. Restore *peerId* in connected clients with new device handle.
3. Emit `peer_status` event for *peerId* with status `"connected"`.
4. Send Roster to reconnected Client.
5. Do NOT emit `peer_joined` (Peer never left the Session).

---

## 8. Migration

### 8.1 Graceful Migration (Host-Initiated)

**BeginGracefulMigration()**
1. Let *successor* = SelectSuccessor().
2. If no successor, return false.
3. Encode migration payload: `sessionId|successorPeerID|maxClients|roomName`.
4. Send `session_migrating` control Packet to all Clients.
5. Schedule departure timer (400ms).
6. On departure timer: call FinishLeave("migration_failed" or clean).

### 8.2 Unexpected Host Recovery (Resilient Only)

**BeginUnexpectedHostRecovery()**
1. If transport is not Resilient, return false.
2. If no valid session info, return false.
3. Remove old Host from Session Peer roster. Add self.
4. Let *successor* = SelectRecoverySuccessor(oldHostID).
5. If no successor, return false.
6. Create MigrationInfo. Set `becomingHost` = (*successor* == localPeerID).
7. Call StartMigration(info).
8. Call BeginMigrationReconnect().
9. Return true.

### 8.3 Successor Selection

**SelectSuccessor()**
1. Collect all connected client Peer IDs.
2. Sort lexicographically (ascending).
3. Return first element. If none, return empty.

**SelectRecoverySuccessor(excludeHostID)**
1. Collect all Session Peer IDs.
2. Exclude *excludeHostID*.
3. Sort lexicographically (ascending).
4. Return first element. If none, return empty.

### 8.4 Migration Reconnect

**BeginMigrationReconnect()**
1. If becoming Host: call BeginHostingSession with migration session info.
2. Else: start scan to find new Host's advertisement.
3. Schedule migration timeout (3 seconds). On timeout: call FailMigration().

---

## 9. Heartbeat

**StartHeartbeat(interval)**
1. If *interval* <= 0, return.
2. Schedule repeating timer at *interval* seconds.
3. On each tick:
   a. If not hosting, or no connected Clients, or no stored broadcast Packet, skip.
   b. Send stored broadcast Packet to all connected Clients via NotifyClients.

The Heartbeat ensures that the most recent broadcast state is re-delivered to clients, covering BLE notification losses and keeping the connection alive.

---

## 10. Deduplication

**IsDuplicate(fromPeerID, msgType, nonce)**
1. Let *key* = fromPeerID + ":" + msgType + ":" + nonce.
2. Prune entries older than 5 seconds from the dedup list.
3. Prune entries exceeding the dedup window (default 64), removing oldest first.
4. If *key* exists in the lookup set, return true (duplicate).
5. Add *key* to list and lookup set with current timestamp.
6. Return false.

Applied only to `"data"` kind Packets. Control Packets are never deduplicated.

---

## 11. Codec (Payload Serialization)

Application payloads are serialized using a binary codec.

### 11.1 Version

First byte of encoded data is always `0x01`.

### 11.2 Type Tags

| Tag | Value | Encoded As |
|-----|-------|-----------|
| Nil | `0x00` | Tag only |
| False | `0x01` | Tag only |
| True | `0x02` | Tag only |
| Number | `0x03` | Tag + 8-byte IEEE 754 double (little-endian) |
| String | `0x04` | Tag + 4-byte LE length + UTF-8 bytes |
| Array | `0x05` | Tag + 4-byte LE count + encoded elements (indexed 1..N) |
| Map | `0x06` | Tag + 4-byte LE count + key-value pairs (keys sorted lexicographically) |

### 11.3 Rules

1. Maximum nesting depth: 64.
2. Tables with contiguous 1-based integer keys are encoded as Arrays. All other tables as Maps.
3. Map keys must be strings. Map keys are sorted lexicographically.
4. Trailing bytes after a complete decode are rejected.

---

## 12. Event Types

Events are delivered to the application via `poll()`. Each event is a table with a `type` field and additional fields.

| Event | Fields | Trigger |
|-------|--------|---------|
| `room_found` | room_id, session_id, name, transport, peer_count, max, rssi | Scan discovers a Room |
| `room_lost` | room_id | A previously discovered Room is no longer visible |
| `hosted` | session_id, peer_id, transport, peers | Local device started hosting |
| `joined` | session_id, room_id, peer_id, host_id, transport, peers | Local device joined a Room |
| `peer_joined` | peer_id, peers | A new Peer entered the Session |
| `peer_left` | peer_id, reason, peers | A Peer left the Session |
| `peer_status` | peer_id, status | A Peer's connection status changed ("reconnecting" or "connected") |
| `message` | peer_id, msg_type, payload | A data message was received |
| `session_migrating` | old_host_id, new_host_id | Host role is being transferred |
| `session_resumed` | session_id, new_host_id, peers | Session resumed after migration |
| `session_ended` | reason | Session was terminated |
| `error` | code, detail | An error occurred |
| `diagnostic` | platform, message | Internal BLE diagnostic message |
| `radio` | state | Bluetooth radio state changed ("on", "off", "unauthorized", "unsupported") |

---

## 13. Client Disconnect Decision Tree

When a Client's BLE connection to the Host drops:

```
OnClientDisconnected(wasJoined, shouldEmit):
1. Call StopClientOnly() to clean up GATT state.
2. If active Migration exists:
     → BeginMigrationReconnect(). Return.
3. If shouldEmit AND wasJoined AND transport is Resilient:
     → Attempt BeginUnexpectedHostRecovery().
     → If successful, return.
4. If shouldEmit AND wasJoined:
     → Attempt BeginClientReconnect().
     → If successful, return.
5. If shouldEmit:
     → Call FinishLeave(null).
     → If wasJoined: emit session_ended("host_lost").
     → Else: emit error("join_failed", detail).
```

---

## 14. Host Client-Disconnect Decision Tree

When the Host detects a Client disconnected:

```
OnHostClientDisconnected(deviceKey):
1. Remove device from pending clients, MTU map, notification queues.
2. Look up Peer ID from device-peer map. Remove mapping.
3. If Peer ID found:
     a. Remove from connected clients map.
     b. If hosting AND not in migration departure:
          → BeginPeerReconnectGrace(peerID). Return.
     c. Else:
          → RemoveSessionPeer(peerID).
```

---

## 15. Write Serialization

### 15.1 Client Write Queue

All Fragments destined for the Host are enqueued in a FIFO queue. Only one write may be in-flight at a time.

**PumpClientWriteQueue()**
1. If a write is already in-flight, return.
2. Peek the first Fragment from the queue.
3. If queue is empty, return.
4. Write Fragment to the Message Characteristic.
5. Set `writeInFlight` = true.
6. On write callback:
   a. Remove the written Fragment from queue.
   b. Set `writeInFlight` = false.
   c. If write failed, clear queue and emit error.
   d. Else call PumpClientWriteQueue() (process next).

### 15.2 Host Notification Queue

Each connected Client device has an independent FIFO queue.

**PumpNotificationQueue(device)**
1. Get the queue for *device*.
2. If empty, return.
3. Peek first Fragment.
4. Send notification to *device* via GATT Server.
5. On notification sent callback:
   a. Remove Fragment from queue.
   b. If queue not empty, call PumpNotificationQueue(*device*).

---

## 16. MTU

| Parameter | Value |
|-----------|-------|
| Default ATT MTU | 23 bytes |
| Desired ATT MTU | 185 bytes |
| ATT Payload Overhead | 3 bytes |
| Fragment Header | 5 bytes |

**Effective chunk size** = negotiated MTU - 3 (overhead) - 5 (fragment header).

At default MTU (23): chunk size = 15 bytes per fragment.
At desired MTU (185): chunk size = 177 bytes per fragment.

---

## 17. Timeouts and Intervals

| Constant | Default | Purpose |
|----------|---------|---------|
| Heartbeat Interval | 2.0s | Re-broadcast cadence |
| Fragment Spacing | 15ms | Minimum delay between fragment sends |
| Assembly Timeout | 15s | Max time to receive all fragments of one packet |
| Migration Timeout | 3s | Max time to complete migration reconnect |
| Migration Departure Delay | 400ms | Delay after broadcasting migration before leaving |
| Reconnect Timeout | 10s | Grace window for transient disconnects |
| Dedup Expiry | 5s | Time before dedup entries expire |
| Dedup Window | 64 | Max tracked dedup entries |
| Room Expiry | 4s | Time before undiscovered room is removed |
| Write Retry Timeout | 1.5s | Write retry window |
| Write Retry Max | 5 | Max write retries |
