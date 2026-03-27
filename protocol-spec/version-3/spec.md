# BLE Game Network Protocol Specification

**Version:** 3.0.0
**Version Note:** Major — breaking changes to client disconnect handling (signature and derivation), teardown scope (new FinishLeaveClient procedure), connection failure paths (new ConnectToRoom step 8), lifecycle integration (new Section 6.7), departure signaling (new control message), and migration convergence (new scan-time resolution rules) relative to v2.0.0.
**Revision Basis:** Consolidated from two independent proposals against v2.0.0, with six post-consolidation amendments applied. Finalized 2026-03-27.
**Status:** Draft

### Changelog

1. `shouldEmit` derivation defined with reconnect-guard conditions; `OnClientDisconnected` signature changed from parameterized to zero-argument with preconditions; connection failure guard flag added. (Merged, amended)
2. `client_leaving` control message added; `Leave()` amended to send departure message; `OnHostClientDisconnected` amended to check departure intent. (Merged)
3. GATT connection failure path added to `ConnectToRoom` step 8; service discovery and characteristic lookup failures routed through same path; normative connection-failure-handled guard for dual-delivery platforms. (Merged, amended)
4. `FinishLeaveClient()` defined as client-only teardown; `StopClientOnly()` idempotency required; call sites in Section 13, `FailReconnect`, and `ConnectToRoom` updated. (Merged, amended)
5. Application lifecycle integration added (Section 6.7); immediate teardown mechanism defined for termination events. (Merged, amended)
6. Divergent successor elections resolved via "first advertiser wins" scan rule and authoritative `roster_snapshot` on migration-resume reconnection; dual-host transient state characterized. (Merged, amended)
7. Migration Acceptance Window (3s) defined with `BeginHostingMigratedSession` procedure; migration timeout cancelled when successor begins hosting. (Merged, amended)
8. `MaxClients` range [1, 7] application-layer validation expectation stated. (Merged)
9. `membershipEpoch` removed from Room Advertisement encoding in unexpected host recovery advertisement description. (Amended)
10. Deferred: Assert permissions granted underspecified. (Deferred)

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
| **Packet** | A versioned binary envelope containing kind, addressing, message type, message ID, and payload. |
| **Fragment** | A BLE-sized chunk of a Packet, with a 5-byte header for reassembly. |
| **Nonce** | A 16-bit unsigned counter identifying a set of Fragments belonging to one fragmentation event. Scoped to transport reassembly only; has no application-layer deduplication semantics. |
| **Message ID** | A 16-bit unsigned identifier assigned by the sender at the application packet level, independent of fragment nonce. Used as the deduplication key for data packets. |
| **Transport** | The reliability mode: *Reliable* (no recovery) or *Resilient* (auto-migration). `Normal` is an accepted application-layer alias for `Reliable`. The wire protocol uses `'r'` (Reliable) and `'s'` (Resilient) only. |
| **Migration** | The transfer of Host role to a successor Peer when the current Host leaves or is lost. |
| **Reconnect Grace** | A 10-second window during which a disconnected Peer may rejoin without being removed from the Session. |
| **HELLO** | A control Packet sent by a Client to a Host to initiate the join handshake. Payload includes `session_id` and `join_intent`. |
| **Roster** | The set of Peer IDs currently participating in a Session, with per-peer connection status (`connected` or `reconnecting`). Ordered by a monotonically increasing Membership Epoch. |
| **Membership Epoch** | A monotonically increasing integer maintained by the Host, incremented on every membership change (join, leave, grace begin, grace expire). Provides total ordering of roster state. |
| **Roster Snapshot** | An authoritative control message containing the full session roster with membership epoch, host identity, and per-peer connection status. |
| **Heartbeat** | A periodic Host action that re-broadcasts the last broadcast Packet (by Message ID) to all Clients with a fresh fragment nonce, and delivers a roster fingerprint for consistency validation. Restricted to broadcast message classes only. |
| **Dedup** | Duplicate detection based on (Peer ID, message type, Message ID) tuples with time-based expiry. |
| **Codec** | The binary serialization format for application payloads (Lua values to bytes). |
| **CCCD** | Client Characteristic Configuration Descriptor — the standard BLE descriptor for enabling notifications. |
| **shouldEmit** | A boolean derived at the moment of client disconnection that controls whether the disconnect decision tree may emit events or initiate recovery procedures. Derived from `clientLeaving` and, when a reconnect or migration join is in progress, from device-identity comparison against the current join target. Captured before `StopClientOnly()` executes. |
| **FinishLeaveClient** | A client-only teardown procedure that cleans up GATT client state, write queues, dedup state, and fragment assemblies without affecting host state. Distinguished from the full `FinishLeave()` which tears down all session state including host. |
| **Departure Message** | A `"client_leaving"` control packet sent from client to host immediately before intentional disconnection, enabling the host to bypass reconnect grace for that peer. Best-effort delivery; the grace timer is the fallback. |
| **Connection Failure** | A GATT-level event indicating that a connection attempt did not result in a connected state, distinct from a disconnection of an established connection. |
| **Migration Acceptance Window** | A bounded time period (default 3s) after a successor host begins hosting during which it accepts `migration_resume` join intents from peers in the migrated session. |
| **Lifecycle Event** | A platform-level signal indicating a change in application execution state (foregrounding, backgrounding, termination) that may affect BLE resource availability. |

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

**Capacity semantics:**

- `MaxClients` counts non-host client slots only. The host is never counted.
- `PeerCount` counts admitted non-host clients only. The host is never counted. A solo host advertises `PeerCount = '0'`.
- Peers in reconnect grace do not increment `PeerCount`, but their slots remain reserved against `MaxClients` for admission purposes.
- When a room fills between discovery and HELLO, the host responds with `join_rejected(room_full)` per Section 6.5.

### 3.2 Room Name Normalization

**NormalizeRoomName(name)**
1. If *name* is empty or null, return `"Room"`.
2. Replace all pipe characters (`|`), newline (`\n`), and carriage return (`\r`) with space.
3. Trim leading and trailing whitespace.
4. If result is empty, return `"Room"`.
5. If result length exceeds 8, truncate to first 8 characters.
6. Return result.

`NormalizeRoomName()` applies to BLE advertisement encoding only (8-character truncation). Applications may accept longer names locally; the advertised name is a truncated representation.

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
1       2       MessageID       16-bit unsigned, big-endian (see note)
3       4       KindLength      Length of Kind string
7       N       Kind            UTF-8 string: "data" or "control"
7+N     4       FromLength      Length of FromPeerID string
11+N    M       FromPeerID      UTF-8 string (6 chars for peers, may be empty)
11+N+M  4       ToLength        Length of ToPeerID string
15+N+M  P       ToPeerID        UTF-8 string (empty = broadcast, 6 chars = directed)
15+N+M+P 4      TypeLength      Length of MsgType string
19+N+M+P Q      MsgType         UTF-8 string (e.g. "hello", "ping", "chat")
19+N+M+P+Q 4    PayloadLength   Length of payload bytes
23+N+M+P+Q R    Payload         Raw binary bytes (Codec-encoded for data, raw for control)
```

**Constraints:**
- String lengths must not exceed 4096 bytes.
- Payload length must not exceed 65536 bytes.
- Version mismatch causes the Packet to be silently dropped.

**Message ID:** A 16-bit identifier assigned by the sender at the application packet level, independent of fragment nonce. For `"data"` kind Packets, the Message ID is used as the deduplication key (Section 10). For `"control"` kind Packets, the Message ID has no protocol-defined semantics and may be set to any value.

### 4.2 Packet Kinds

| Kind | Purpose |
|------|---------|
| `"data"` | Application message. Payload is Codec-encoded (Section 11). Subject to Dedup. |
| `"control"` | Protocol control message. Payload format depends on MsgType. Not subject to Dedup. |

### 4.3 Control Message Types

| MsgType | Direction | Payload | Purpose |
|---------|-----------|---------|---------|
| `"hello"` | Client → Host | See below | Join handshake initiation |
| `"hello_ack"` | Host → Client | Empty | Admission granted |
| `"join_rejected"` | Host → Client | UTF-8 reason string | Admission denied |
| `"peer_joined"` | Host → Client | Empty | Notify that a Peer entered the Session |
| `"peer_left"` | Host → Client | UTF-8 reason string | Notify that a Peer left the Session |
| `"roster_snapshot"` | Host → Client | See below | Authoritative roster delivery |
| `"roster_request"` | Client → Host | Empty | Request current authoritative roster |
| `"session_migrating"` | Host → Client | Migration payload (Section 8.1) | Host is transferring role |
| `"session_ended"` | Host → Client | UTF-8 reason string | Session has been terminated |
| `"client_leaving"` | Client → Host | Empty | Client signals intentional departure |

**`hello` payload** (pipe-delimited):
```
session_id|join_intent
```
- `session_id` — The Session ID the client believes it is joining. Empty string for a fresh join where no prior session context exists. The client's Peer ID is carried in the packet's `FromPeerID` field.
- `join_intent` — One of: `fresh`, `reconnect`, or `migration_resume`.

**`join_rejected` reasons** (minimum set):
| Reason | Condition |
|--------|-----------|
| `room_full` | Connected clients equal or exceed `max_clients`. |
| `duplicate_peer_id` | A peer with this ID is already in the session. |
| `stale_session` | The `session_id` in the HELLO is non-empty and does not match the current session. |
| `wrong_target` | The packet's `ToPeerID` does not match the current host's Peer ID. |
| `migration_mismatch` | The `join_intent` is `migration_resume` but the host is not in a migration-acceptance state. |

**`roster_snapshot` payload** (pipe-delimited):
```
session_id|host_peer_id|membership_epoch|peer1:status|peer2:status|...
```
- `session_id` — Current session identifier (6-char hex).
- `host_peer_id` — Current host's Peer ID (6-char hex).
- `membership_epoch` — Monotonically increasing integer (decimal string), incremented on every membership change.
- Peer entries — Each formatted as `peerID:status`, where `status` is `connected` or `reconnecting`. The first three fields are fixed; all subsequent pipe-delimited segments are peer entries.

**`roster_snapshot` delivery rules:**
- Host sends `roster_snapshot` immediately after `hello_ack` for fresh joins.
- Host sends `roster_snapshot` after reconnect acceptance.
- Host broadcasts `roster_snapshot` to all clients after any membership change.
- Migration control messages (Section 8.1) must include the current `membership_epoch`.

**`client_leaving` backward compatibility:** A v2 host that receives the unknown `"client_leaving"` control type will silently ignore it (unknown control types are not errors) and proceed with the existing reconnect grace path. A v3 host connecting with a v2 client that does not send `"client_leaving"` will follow the grace path as before. No version negotiation is required.

### 4.4 Message Routing

Roster membership and directed routability are distinct. A peer's presence in the roster (via `roster_snapshot`) indicates session membership. Directed routability requires that the peer has active connection status (`connected`). Peers with status `reconnecting` are session members but are not valid directed message targets. This distinction applies to all routing rules below.

**Routing rules (Host relay behavior):**
- Empty `ToPeerID`: broadcast to all connected clients except sender. Host delivers to self if host is not the sender.
- `ToPeerID` matches a connected client: forward only to that client.
- `ToPeerID` matches the host's own Peer ID: deliver to host, do not relay.
- `ToPeerID` references a peer in reconnect grace or an unknown Peer ID: drop silently.

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

The 16-bit fragment nonce wraps after 65,535 fragmentation events. Fragment nonce is scoped to transport reassembly only (Section 10 uses Message ID for deduplication) and has no dedup implications.

### 5.4 Reassembling Fragments

**ProcessIncomingFragment(sourceKey, fragmentData)**
1. If fragment data length is less than 5 bytes, reject silently.
2. Parse the 5-byte header. Extract *version*, *nonce*, *index*, *count*.
3. If *version* != 1, reject silently.
4. If *count* == 0, reject silently.
5. If *index* >= *count*, reject silently.
6. If *count* == 1, return Fragment payload immediately (single-fragment fast path).
7. Let *assemblyKey* = sourceKey + ":" + nonce.
8. If the number of active assemblies for this source exceeds `Max Concurrent Assemblies Per Source` (Section 17), discard the oldest assembly for this source before proceeding.
9. Look up or create an InboundAssembly for *assemblyKey*.
10. If creating new: initialize with *count* slots, set `updatedAt` to now.
11. If existing and *count* differs from stored count, discard assembly and return null.
12. If slot at *index* is already filled:
   a. If data matches, ignore (benign duplicate).
   b. If data differs, discard entire assembly and return null (conflict).
13. Store chunk at slot *index*. Increment `receivedCount`. Add chunk length to `totalBytes`. Update `updatedAt`.
14. If `receivedCount` < `count`, return null (incomplete).
15. Concatenate all slots in index order into a single byte array.
16. Remove assembly from tracking.
17. If total length exceeds 65536 bytes, emit error and return null.
18. Return reassembled bytes and *nonce*.

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
5. Validate *maxClients* is in range [1, 7]. If outside this range, clamp to the nearest bound. Application-layer validation SHOULD reject values outside [1, 7] before they reach the protocol layer, rather than relying on silent clamping.
6. Initialize *membershipEpoch* to 0.
7. Open a GATT Server.
8. Create the Service with the Message Characteristic (Read, Write, Notify) and CCCD.
9. Add Service to GATT Server.
10. On service added successfully:
    a. Call AdvertiseRoom().
    b. Start Heartbeat timer.
    c. Emit `hosted` event with *sessionId*, local Peer ID, and *transport*.

The Host tracks pending clients: GATT-connected devices that have not completed the `hello` to `hello_ack` exchange. On each heartbeat tick, pending clients older than the Pending Client Timeout (Section 17) are disconnected.

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
   b. Discover services. On failure -> go to step 8.
   c. Find Message Characteristic. If not found -> go to step 8.
   d. Enable notifications via CCCD descriptor write (non-fatal on failure).
   e. Call CompleteLocalJoin().
8. On GATT connection failure (or post-connection setup failure from 7b/7c):
   a. Set `connectionFailureHandled` = true.
   b. Call StopClientOnly().
   c. If `reconnectJoinInProgress` is true:
        -> Set `reconnectJoinInProgress` = false.
        -> Resume reconnect scan. Do not call FailReconnect().
           The reconnect timeout is still running and may yield
           another scan result.
        -> Return.
   d. If `migrationJoinInProgress` is true:
        -> Set `migrationJoinInProgress` = false.
        -> Resume migration scan. Do not call FailMigration().
           The migration timeout is still running and may yield
           another scan result.
        -> Return.
   e. Else (fresh join):
        -> Call FinishLeaveClient().
        -> Emit error("join_failed", "connection_failed") with
           platform-specific detail.

REQUIREMENT: On platforms where GATT connection failure is delivered as a disconnect callback (notably Android's `onConnectionStateChange` with `STATE_DISCONNECTED` and non-zero status), the implementation MUST route the event exclusively through step 8 when `clientJoined` is false and the status indicates connection establishment failure. The Section 13 disconnect tree MUST NOT process the same event. If an implementation cannot guarantee exclusive routing, it MUST check `connectionFailureHandled` at the entry of `OnClientDisconnected()`; if true, clear the flag and return without executing the disconnect tree.

### 6.4 Client Join Completion

**CompleteLocalJoin()**
1. Add local Peer ID and Host Peer ID to Session Peer roster.
2. Enter pending state. Do NOT emit `joined`, `session_resumed`, or any admission event.
3. Determine *joinIntent*:
   - If reconnect is in progress: `"reconnect"`.
   - Else if migration join is in progress: `"migration_resume"`.
   - Else: `"fresh"`.
4. Determine *sessionId*:
   - If *joinIntent* is `"fresh"` and no prior session context exists: empty string.
   - Otherwise: the saved *joinedSessionId*.
5. Encode and enqueue a HELLO control Packet (from=localPeerID, to=hostPeerID, type=`"hello"`, payload=`sessionId|joinIntent`).
6. Await host response (`hello_ack` or `join_rejected`).

**OnHelloAckReceived()**
1. Set `clientJoined` = true.
2. If reconnect is in progress, call CompleteReconnectResume().
3. Else if migration join is in progress, call CompleteMigrationResume().
4. Else emit `joined` event with session info.

**OnJoinRejectedReceived(reason)**
1. Disconnect from the host.
2. Emit `join_failed` event with *reason* and *roomId*.

### 6.5 HELLO Handshake (Host Side)

**OnHelloReceived(sourceDeviceKey, packet)**
1. Let *peerId* = packet.fromPeerId. If empty, disconnect device, return.
2. Parse payload: extract *sessionId* and *joinIntent* from the HELLO payload.
3. Validate admission:
   a. If connected clients >= *maxClients* and *peerId* is not in Reconnect Grace: send `join_rejected("room_full")` to device, disconnect device, return.
   b. If *peerId* is already in connected clients map: send `join_rejected("duplicate_peer_id")` to device, disconnect device, return.
   c. If *sessionId* is non-empty and does not match current session: send `join_rejected("stale_session")` to device, disconnect device, return.
   d. If packet.toPeerID does not match the local host Peer ID: send `join_rejected("wrong_target")` to device, disconnect device, return.
   e. If *joinIntent* is `"migration_resume"` and the host is not in a migration-acceptance state: send `join_rejected("migration_mismatch")` to device, disconnect device, return.
4. Remove device from pending clients.
5. Bind: map *sourceDeviceKey* → *peerId* in device-peer map.
6. Bind: map *peerId* → device in connected clients.
7. Send `hello_ack` control Packet to the client.
8. If *peerId* is in Reconnect Grace:
   a. Cancel the grace timer for *peerId*.
   b. Update *peerId* status to `connected` in Session Peer roster. Increment *membershipEpoch*.
   c. Emit `peer_status` event with status `"connected"`.
   d. Broadcast `roster_snapshot` to all connected Clients.
9. Else (new peer):
   a. Add *peerId* to Session Peer roster with status `connected`. Increment *membershipEpoch*.
   b. Emit `peer_joined` event.
   c. Broadcast `peer_joined` control to all other Clients.
   d. Broadcast `roster_snapshot` to all connected Clients.
10. Update advertisement (peer count changed).

### 6.6 Leaving a Session

**Leave()**
1. If hosting with Resilient transport and clients exist:
   a. Attempt BeginGracefulMigration().
   b. If successful, return.
2. If connected as client AND `clientJoined` is true:
   a. Encode and send a `"client_leaving"` control Packet
      (from=localPeerID, to=hostPeerID, type="client_leaving", payload=empty).
   b. Set `clientLeaving` = true.
   c. Wait up to Departure Send Timeout (100ms, Section 17) for write callback.
      On timeout or write failure, proceed immediately.
   d. Call FinishLeave(null).
   e. Return.
3. Call FinishLeave(reason=null for client, "host_left" for host).

Write failure in step 2c is non-fatal. The departure message is best-effort; the host's grace timer serves as the fallback for delivery failure.

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

**FinishLeaveClient()**
1. Call StopClientOnly() to clean up GATT client state.
2. Clear client-side dedup state.
3. Clear client-side fragment assemblies.
4. Set `clientJoined` = false.
5. Set `clientLeaving` = true.

POSTCONDITIONS:
- GATT client connection is closed.
- Client write queue is empty.
- No in-flight client writes remain.
- Host state (GATT server, host timers, host session info) is unaffected.

REQUIREMENT: `StopClientOnly()` MUST be idempotent. Calling it when GATT client state is already cleaned up (null references, empty queues) MUST be a no-op with no side effects. This is required because the Client Disconnect Decision Tree (Section 13) calls `StopClientOnly()` at step 4, and if recovery attempts at steps 5-7 all fail, step 8a/9a calls `FinishLeaveClient()` whose step 1 calls `StopClientOnly()` again.

`FinishLeaveClient()` is used instead of `FinishLeave(null)` at the following call sites:
- Section 13 (Client Disconnect Decision Tree), steps 8a and 9a.
- Section 7.1 `FailReconnect()`, step 4.
- Section 6.3 `ConnectToRoom` step 8e.

`FinishLeave(remoteReason)` is the full teardown procedure, used by:
- `Leave()` (Section 6.6) — intentional leave by client or host.
- `BeginGracefulMigration()` step 8 (Section 8.1) — host departure after migration broadcast.
- `OnAppLifecycleChanged()` termination handling (Section 6.7) — immediate teardown.

### 6.7 Application Lifecycle Integration

The protocol layer MUST register for platform-level application lifecycle events and invoke protocol actions in response.

```
FUNCTION OnAppLifecycleChanged(newState) -> void

  1. If newState is "background" or "inactive":
     1a. If hosting is true AND transport is Resilient AND connected client count > 0:
         -> Invoke Leave(). This triggers BeginGracefulMigration()
            per Section 6.6 step 1.
     1b. Else if hosting is true:
         -> Invoke Leave(). This sends session_ended and tears down.
     1c. If connected as client:
         -> No automatic action. The client retains its connection.
            If the OS subsequently drops the connection, the standard
            disconnect decision tree (Section 13) handles recovery.
  2. If newState is "terminating":
     2a. If hosting is true AND transport is Resilient AND connected client count > 0:
         -> Send session_migrating to all clients (best-effort, no delivery wait).
         -> Call FinishLeave("host_left") immediately.
            Do not schedule the Migration Departure Delay (Section 8.1 step 7).
            Do not wait for the Departure Send Timeout (Section 17).
            Clients will detect host loss via disconnect callback and
            enter unexpected host recovery (Section 8.2).
     2b. Else:
         -> Call FinishLeave(null) immediately.
            Do not send the client_leaving departure message (Section 6.6 step 2a).
            Do not wait for any write callback.
  3. If newState is "foreground":
     3a. No automatic action. If the session was lost during background,
         the client disconnect decision tree (Section 13) will have
         already handled it.

ERRORS:
  - Leave() fails during background transition (e.g., GATT server
    already torn down by OS) -> attempt FinishLeave("host_left")
    to clean up local state. Session may enter unexpected recovery
    on the client side.
  - Termination handler is interrupted by OS before FinishLeave
    completes -> client-side recovery handles the abrupt host loss.
    No protocol-level mitigation is possible.
  - Insufficient background execution time for graceful migration ->
    migration may be interrupted by OS. Clients fall back to
    unexpected host recovery (Section 8.2).
```

**Platform mapping (informative, not normative):**

| Lifecycle Event | Android | iOS |
|----------------|---------|-----|
| App entering background | `onPause()` or `onStop()` in Activity | `applicationDidEnterBackground` or `willResignActive` |
| App will terminate | `onDestroy()` in Activity | `applicationWillTerminate` |
| App entering foreground | `onResume()` in Activity | `applicationDidBecomeActive` |

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
4. Call FinishLeaveClient().
5. Emit `session_ended` event with reason `"host_lost"`.

**OnReconnectTimeout()**
1. Call FailReconnect().

### 7.2 Host Reconnect Grace

Triggered when a Client's BLE connection drops on the Host side.

**BeginPeerReconnectGrace(peerId)**
1. Remove *peerId* from connected clients map (device handle is dead).
2. Do NOT remove *peerId* from Session Peer roster.
3. Update *peerId* status to `reconnecting` in Session Peer roster. Increment *membershipEpoch*.
4. Do NOT notify other Clients of departure.
5. Emit `peer_status` event for *peerId* with status `"reconnecting"`.
6. Broadcast `roster_snapshot` to all connected Clients.
7. Schedule a per-peer Grace Timeout (default 10 seconds).
8. Update advertisement (available slot opened).

**OnGraceTimeout(peerId)**
1. Remove *peerId* from Session Peer roster. Increment *membershipEpoch*.
2. Emit `peer_left` event with reason `"timeout"`.
3. Send `peer_left` control to all remaining Clients.
4. Broadcast `roster_snapshot` to all connected Clients.
5. Update advertisement.

**OnReconnectHello(peerId)**

Reconnecting peers follow the standard admission path (Section 6.5). On successful admission, Section 6.5 step 8 handles the reconnect case: cancels the grace timer, updates peer status, increments epoch, and broadcasts `roster_snapshot`.

---

## 8. Migration

### 8.1 Graceful Migration (Host-Initiated)

**BeginGracefulMigration()**
1. Cancel all reconnect grace timers. Remove all grace peers from Session Peer roster. Increment *membershipEpoch*. Grace peers are treated as departed.
2. Let *successor* = SelectSuccessor().
3. If no successor, return false.
4. Encode migration payload: `sessionId|successorPeerID|maxClients|roomName|membershipEpoch`.
5. Send `session_migrating` control Packet to all Clients.
6. Stop accepting new data writes. Continue pumping existing notification queues until departure.
7. Schedule departure timer (400ms).
8. On departure timer: call FinishLeave("migration_failed" or clean).

Data in flight during the migration window may be lost. Applications should treat migration as a potential data boundary. The protocol does not guarantee recovery of messages that were in write queues or partial assembly at the time `session_migrating` was sent.

### 8.2 Unexpected Host Recovery (Resilient Only)

**BeginUnexpectedHostRecovery()**
1. If transport is not Resilient, return false.
2. If no valid session info, return false.
3. Remove old Host from Session Peer roster. Add self.
4. Remove any peers known to be in reconnect grace from the candidate set.
5. Let *successor* = SelectRecoverySuccessor(oldHostID).
6. If no successor, return false.
7. Create MigrationInfo. Set `becomingHost` = (*successor* == localPeerID).
8. Call StartMigration(info).
9. Call BeginMigrationReconnect().
10. If `becomingHost` is true AND GATT server started successfully:
    a. The Room Advertisement encodes the migrated session info
       (same sessionId, localPeerID as new host, same maxClients,
       roomName). The current `membershipEpoch` is not carried in the
       advertisement (the wire format has no field for it); it is
       delivered to reconnecting peers via `roster_snapshot` after
       the hello handshake completes.
    b. Remaining clients discover the new host via scan during
       `BeginMigrationReconnect()` and connect with
       `join_intent="migration_resume"`.
11. Return true.

ERRORS:
- GATT server fails to start -> successor is treated as failed; convergence fallback applies (Section 8.3).

### 8.3 Successor Selection

**SelectSuccessor()**
1. Collect all connected client Peer IDs (excluding peers in reconnect grace).
2. Sort lexicographically (ascending).
3. Return first element. If none, return empty.

**SelectRecoverySuccessor(excludeHostID)**
1. Collect all Session Peer IDs with status `connected` (excluding peers in reconnect grace).
2. Exclude *excludeHostID*.
3. Sort lexicographically (ascending).
4. Return first element. If none, return empty.

During unexpected host recovery, all electing peers MUST use the roster associated with the highest `membership_epoch` known locally. The roster used for election MUST exclude: (a) the old host, (b) any peers with status `reconnecting`, and (c) any peers previously excluded by the convergence fallback. Peers must not elect successors from ad-hoc local memory. If peers have divergent rosters due to in-flight roster updates at the time of host loss, the "first advertiser wins" rule (Section 8.4 `OnScanResultDuringMigration` step 3) is the primary convergence mechanism. The new host's `roster_snapshot` delivered after migration-resume reconnection is the authoritative state that resolves any remaining divergence across all reconnected peers.

**Convergence Fallback:**
If the elected successor does not begin advertising within the Migration Timeout (default 3 seconds, Section 17), remaining clients re-run successor election with that peer excluded from the candidate set. This repeats until a successor advertises or the candidate set is exhausted, at which point the session is considered lost and `session_ended` is emitted.

### 8.4 Migration Reconnect

**BeginMigrationReconnect()**
1. If becoming Host: call BeginHostingMigratedSession with migration session info.
2. Else: start scan to find new Host's advertisement.
3. Schedule migration timeout (3 seconds). On timeout: call FailMigration().

**BeginHostingMigratedSession(migrationInfo)**

When the successor begins hosting a migrated session:

1. Start GATT server with migrated session info
   (sessionId, roomName, maxClients, membershipEpoch).
1a. Cancel the migration timeout scheduled by `BeginMigrationReconnect()`
    step 3. The successor is now hosting; the migration timeout applies
    to the reconnecting-client path, not the hosting path.
2. Set `migrationAcceptanceActive` = true.
3. Begin advertising the room.
4. Start Heartbeat timer.
5. Emit `hosted` event.
6. Schedule Migration Acceptance Window timer (default 3 seconds, Section 17).
7. On Migration Acceptance Window expiry:
   a. Set `migrationAcceptanceActive` = false.
   b. Any subsequent join with intent="migration_resume" is
      rejected with "migration_mismatch" per Section 6.5 step 3e.

ERRORS:
- GATT server fails to start -> emit error, session is lost.
- No peers connect within acceptance window -> window expires,
  host continues operating with current roster. Peers arriving
  later with fresh join intent are accepted normally.

**OnSessionMigratingReceived()**

On receiving `session_migrating`, the Client:
1. Discards its write queue.
2. Clears all in-progress fragment assemblies.
3. Proceeds with migration reconnect per BeginMigrationReconnect().

**OnScanResultDuringMigration(room)**

When a client is scanning for the successor during migration reconnect:

1. If room.sessionId does not match the current session ID, ignore.
2. If room.hostPeerId matches the locally elected successor:
   a. Connect to room with migrationJoin=true.
3. Else if room.hostPeerId is a known session member
   (present in the local roster at time of host loss):
   a. Accept this peer as the new successor.
   b. Update migration info with new successor identity.
   c. Connect to room with migrationJoin=true.
4. Else: ignore (unknown advertiser, not a session member).

ERRORS:
- Connection to accepted successor fails -> resume scan.
  Migration timeout still applies.

**Dual-host transient state:** If two clients both believe they are the successor and both start GATT servers, two rooms with the same session ID will be advertising simultaneously. The "first discovered wins" rule causes each scanning client to connect to whichever successor it discovers first. If all scanning clients discover the same successor, the other successor receives no connections and emits `session_ended` when its Migration Acceptance Window expires — resolving the dual-host state. If different clients connect to different successors, the result is a persistent session split: two independent sessions operating with the same `sessionId` but divergent rosters. Neither host is aware of the other. The protocol does not provide a split-resolution mechanism; both sessions continue independently until they end by other means. The probability of a persistent split is low in the target environment (small peer counts in close physical proximity produce similar BLE discovery ordering), but it is not zero.

### 8.5 CompleteMigrationResume

**CompleteMigrationResume()**
1. Cancel Migration Timeout.
2. Clear migration state fields (pending successor, migration session info).
3. Set local *membershipEpoch* to the epoch received in the migration control message.
4. Emit `session_resumed` event with:
   - `session_id`: the migrated session's ID.
   - `new_host_id`: the successor's Peer ID.
   - `peers`: the current peer roster.

---

## 9. Heartbeat

**StartHeartbeat(interval)**
1. If *interval* <= 0, return.
2. Schedule repeating timer at *interval* seconds.
3. On each tick:
   a. If not hosting, skip.
   b. Disconnect any pending clients older than the Pending Client Timeout (Section 17).
   c. Compute the roster fingerprint: CRC32 of the sorted, concatenated `peerID:status` pairs in the current roster, where `status` is `c` (connected) or `r` (reconnecting). Pairs are pipe-delimited. Example input: `A1B2C3:c|D4E5F6:r|G7H8I9:c`.
   d. Deliver the 4-byte roster fingerprint to all connected Clients.
   e. If no connected Clients or no stored broadcast Packet, skip to next tick.
   f. Re-send the stored broadcast Packet to all connected Clients via NotifyClients, using the stored Message ID and a fresh fragment nonce.

The Heartbeat re-broadcasts only broadcast messages (empty `ToPeerID`). Directed messages are not replayed by the Heartbeat.

**Client-side roster fingerprint handling:**
On receiving a heartbeat roster fingerprint, the Client compares it to the CRC32 of its own local roster (computed using the same algorithm). On mismatch, the Client sends a `roster_request` control message to the Host. The Host responds with a `roster_snapshot` containing the current authoritative roster. A Client must not send `roster_request` more than once per heartbeat interval.

---

## 10. Deduplication

**IsDuplicate(fromPeerID, msgType, messageID)**
1. Let *key* = fromPeerID + ":" + msgType + ":" + messageID.
2. Prune entries older than 5 seconds from the dedup list.
3. Prune entries exceeding the dedup window (default 64), removing oldest first.
4. If *key* exists in the lookup set, return true (duplicate).
5. Add *key* to list and lookup set with current timestamp.
6. Return false.

Applied only to `"data"` kind Packets. Control Packets are never deduplicated.

The 16-bit `message_id` wraps after 65,535 messages. At typical BLE throughput (well under 1,000 packets/second), collision with the dedup window (5 seconds, 64 entries) requires sustained rates exceeding 13,000 packets/second. This is not a practical concern.

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
5. Empty table (no keys) encodes as Array with count 0: type tag `0x05` followed by 4-byte little-endian `0x00000000`.

---

## 12. Event Types

Events are delivered to the application via `poll()`. Each event is a table with a `type` field and additional fields.

| Event | Fields | Trigger |
|-------|--------|---------|
| `room_found` | room_id, session_id, name, transport, peer_count, max, rssi | Scan discovers a Room |
| `room_lost` | room_id | A previously discovered Room is no longer visible |
| `hosted` | session_id, peer_id, transport, peers | Local device started hosting |
| `joined` | session_id, room_id, peer_id, host_id, transport, peers | Local device admitted to a Room (after `hello_ack`) |
| `join_failed` | reason, room_id | Admission denied by host (after `join_rejected`) |
| `peer_joined` | peer_id, peers | A new Peer entered the Session |
| `peer_left` | peer_id, reason, peers | A Peer left the Session |
| `peer_status` | peer_id, status | A Peer's connection status changed ("reconnecting" or "connected") |
| `message` | peer_id, msg_type, payload | A data message was received |
| `session_migrating` | old_host_id, new_host_id | Host role is being transferred |
| `session_resumed` | session_id, new_host_id, peers | Session resumed after migration (emitted by CompleteMigrationResume) |
| `session_ended` | reason | Session was terminated |
| `error` | code, detail | An error occurred |
| `diagnostic` | platform, message | Internal BLE diagnostic message |
| `radio` | state | Bluetooth radio state changed ("on", "off", "unauthorized", "unsupported") |

**Error codes** (used with the `error` event type):
| Code | Detail | Context |
|------|--------|---------|
| `write_failed` | Platform-specific BLE error string | Write to host or notification to client failed (Section 15) |
| `send_failed` | — | Chunk size too small for fragmentation |
| `payload_too_large` | — | Packet exceeds 255 fragments |
| `room_gone` | — | Room not found during join |

Note: The `join_failed` event is a distinct event type (not an `error` event). Host rejection is reported via `join_failed`; BLE connection failure during join is reported via `error` with code `join_failed` (Section 6.3 step 8e, Section 13 step 8c).

---

## 13. Client Disconnect Decision Tree

When a Client's BLE connection to the Host drops:

```
PRECONDITION:
  Let wasJoined = clientJoined (true if hello_ack was received for current connection).

FUNCTION OnClientDisconnected() -> void

  1. If connectionFailureHandled is true:
     1a. Set connectionFailureHandled = false. Return.
  2. Capture wasJoined from precondition above.
  3. Derive shouldEmit:
     3a. If clientLeaving is true -> shouldEmit = false.
     3b. Else if reconnectJoinInProgress is true AND the disconnected
         device is not the GATT device for the current reconnect attempt
         -> shouldEmit = false.
     3c. Else if migrationJoinInProgress is true AND the disconnected
         device is not the GATT device for the current migration attempt
         -> shouldEmit = false.
     3d. Else -> shouldEmit = true.
  4. Call StopClientOnly().
  5. If migrationInProgress is true:
     5a. Call BeginMigrationReconnect(). Return.
  6. If shouldEmit is true AND wasJoined is true AND transport is Resilient:
     6a. Call BeginUnexpectedHostRecovery().
     6b. If successful, return.
  7. If shouldEmit is true AND wasJoined is true:
     7a. Call BeginClientReconnect().
     7b. If successful, return.
  8. If shouldEmit is true:
     8a. Call FinishLeaveClient().
     8b. If wasJoined is true: emit session_ended with reason "host_lost".
     8c. Else: emit error with code "join_failed" and platform-specific detail.
     8d. Return.
  9. Otherwise:
     9a. Call FinishLeaveClient(). No events emitted.
```

**Key invariants:**
- `wasJoined` and `shouldEmit` are captured *before* `StopClientOnly()` modifies state (steps 2-3 before step 4).
- The `shouldEmit` derivation is defined as `NOT clientLeaving` with device-identity guards, not as a GATT handle comparison. Implementations must not use handle comparison, which fails when `StopClientOnly()` nulls the handle before the callback fires.
- Steps 8 and 9 call `FinishLeaveClient()` (Section 6.6), not full `FinishLeave()`.
- Disconnect callbacks for stale devices during active reconnect or migration joins are suppressed (steps 3b/3c).
- Disconnects during intentional leave are suppressed (step 3a).

---

## 14. Host Client-Disconnect Decision Tree

When the Host detects a Client disconnected:

**OnClientLeavingReceived(sourceDeviceKey, packet)**
1. Let *peerId* = packet.fromPeerId.
2. If *peerId* is empty or not in connected clients, return.
3. Record departure intent for *peerId* with current timestamp.
4. Do not disconnect the device. The client will disconnect itself.

**OnHostClientDisconnected(deviceKey)**
1. Remove device from pending clients, MTU map, notification queues.
2. Look up Peer ID from device-peer map. Remove mapping.
3. If Peer ID found:
   a. Remove from connected clients map.
   b. If a departure intent was recorded for this Peer ID
      within the last Departure Intent Expiry (2 seconds, Section 17):
        -> Remove Peer from Session Peer roster.
           Increment *membershipEpoch*.
        -> Emit `peer_left` event with reason `"left"`.
        -> Broadcast `peer_left` control to all remaining Clients.
        -> Broadcast `roster_snapshot` to all connected Clients.
        -> Update advertisement. Return.
   c. If hosting AND not in migration departure:
        -> BeginPeerReconnectGrace(peerID). Return.
   d. Else:
        -> RemoveSessionPeer(peerID).

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
   c. If write failed, clear queue and emit error `"write_failed"` with platform-specific BLE error detail.
   d. Else call PumpClientWriteQueue() (process next).

On receiving `session_migrating`, the Client discards its write queue (Section 8.4).

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

## 17. Timeouts, Intervals, and Limits

| Constant | Default | Purpose |
|----------|---------|---------|
| Heartbeat Interval | 2.0s | Re-broadcast and roster fingerprint cadence |
| Fragment Spacing | 15ms | Recommended pacing between fragment sends (advisory) |
| Assembly Timeout | 15s | Max time to receive all fragments of one packet |
| Migration Timeout | 3s | Max time to complete migration reconnect |
| Migration Departure Delay | 400ms | Delay after broadcasting migration before leaving |
| Migration Acceptance Window | 3s | Duration after successor begins hosting during which `migration_resume` join intents are accepted |
| Reconnect Timeout | 10s | Grace window for transient disconnects |
| Pending Client Timeout | 5s | Max time for GATT-connected device to complete hello/hello_ack |
| Departure Send Timeout | 100ms | Max time client waits for departure message write callback before proceeding with disconnect |
| Departure Intent Expiry | 2s | Max time between receiving a departure intent and the corresponding disconnect callback for the intent to be honored |
| Dedup Expiry | 5s | Time before dedup entries expire |
| Dedup Window | 64 | Max tracked dedup entries |
| Room Expiry | 4s | Time before undiscovered room is removed |
| Max Concurrent Assemblies Per Source | 32 | Max in-progress fragment assemblies per source peer |

`Fragment Spacing` is an implementation-advisory timing hint. It is a recommended default for pacing fragment writes on platforms where back-to-back BLE writes cause congestion. It carries no interoperability requirement — implementations may use different pacing strategies without violating the protocol.
