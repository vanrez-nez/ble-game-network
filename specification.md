# BLE Game Network API — Specification

**Version:** 1.1.0
**Target:** Love2D / Lua native bridge
**Platforms:** iOS, Android
**Transport:** Bluetooth Low Energy (BLE 4.0+)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Background and Design Rationale](#2-background-and-design-rationale)
3. [Core Concepts](#3-core-concepts)
4. [State Machine](#4-state-machine)
5. [Transport Profiles](#5-transport-profiles)
6. [API Reference](#6-api-reference)
7. [Events Reference](#7-events-reference)
8. [Error Codes](#8-error-codes)
9. [Constraints and Limits](#9-constraints-and-limits)
10. [Native Bridge Contract](#10-native-bridge-contract)
11. [Usage Patterns](#11-usage-patterns)

---

## 1. Overview

A single-module API for local multiplayer over BLE. The library abstracts radio
management, GATT roles, connection lifecycle, payload serialization, and
graceful host migration behind game-oriented primitives.

All operations are non-blocking. Results and state changes are delivered as
events through `poll()`. Game code never encodes or decodes transport payloads
manually.

The API is designed around three principles:

- **Poll-based I/O.** No callbacks into Lua. All incoming data and state
  changes flow through a single `poll()` call per frame.

- **Intent-driven lifecycle.** The caller declares intent with `host()`,
  `scan()`, `join()`, and `leave()`. There are no public stop or disconnect
  primitives beyond `leave()`.

- **Role-agnostic game code.** Game logic should not branch on host versus
  client behavior. Transport topology is selected once at `host()` time.

---

## 2. Background and Design Rationale

### Why BLE

Both iOS and Android expose BLE Central and Peripheral roles to foreground
apps without special entitlements. BLE is the only radio both platforms provide
symmetrically without network infrastructure. Wi-Fi Direct is unavailable on
iOS for third-party apps. Google Nearby Connections and Apple Multipeer
Connectivity do not interoperate offline. Raw BLE GATT is the viable
cross-platform offline transport.

### Why GATT

A GATT connection provides acknowledged delivery at the radio level, larger
negotiated payloads than advertisement data, bidirectional flow, and
predictable latency once connected. The connection setup cost is paid once at
session join time.

### Why Poll Instead of Callbacks

Love2D runs a single-threaded main loop. BLE events originate on OS-managed
threads. Delivering callbacks directly onto the Lua thread risks re-entrancy,
requires synchronization, and can introduce frame jitter. A native event queue
drained by `poll()` gives the game loop full control over when network work is
processed.

### On Payload Handling

Application code should pass plain Lua values to `broadcast()` and `send()`
and receive plain Lua values from `message` events. The bridge owns payload
serialization, wire encoding, and decoding. Payload format is not part of the
application contract.

### On Host Migration

BLE GATT is naturally a star topology: one Peripheral (host), many Centrals
(clients). `RESILIENT` keeps that topology but adds graceful handoff when the
host intentionally leaves. The current host selects a successor from the known
roster, announces the handoff, and the remaining peers reconnect to the new
host. Unexpected host loss is not recoverable and ends the session.

---

## 3. Core Concepts

**Room**
A discoverable hosted session. Has a human-readable name visible to scanning
players, a capacity limit, a transport profile, and a stable `session_id`.

**Session**
The active network context after a successful `host()` or `join()`. Ends when
the local device calls `leave()`, when the remote host ends the session, or
when a fatal transport failure occurs.

**Session ID**
A stable identifier for a session. In `RESILIENT`, the same `session_id`
survives graceful host migration.

**Peer**
Any participant in the session, including the local device. Each peer has a
stable `peer_id` for the lifetime of the session.

**Host**
The device currently advertising the session and acting as the GATT
Peripheral. In `RESILIENT`, the host may change after a graceful migration.

**Transport Profile**
A named configuration that determines delivery guarantees and host behavior.
Declared by the host at `host()` time and immutable for the lifetime of the
session.

**Payload**
A Lua value supported by the bridge serializer. Supported types are listed in
[Native Bridge Contract](#10-native-bridge-contract). Application code treats
payloads as ordinary Lua values.

---

## 4. State Machine

The local device is always in exactly one of these public states:

```
IDLE
  │
  ├─ host() ───────────────────────────────► HOSTING
  │                                           │
  │                                     "hosted" event
  │                                           │
  │                                           ▼
  └─ scan() ───────────────────────────────► SCANNING
                                                │
                                              join()
                                                │
                                                ▼
                                           CONNECTING
                                                │
                                         "joined" event
                                                │
                     ┌──────────────────────────▼──────────────────────────┐
                     │                    IN_SESSION                       │
                     │        (host and client both land here)             │
                     └──────────────────────────┬──────────────────────────┘
                                                │
                                             leave()
                                      or terminal session event
                                                │
                                                ▼
                                              IDLE
```

**Transitions:**

- `host()` is only meaningful from `IDLE`. Success produces `hosted`.
- `scan()` is only meaningful from `IDLE`.
- `join()` is only valid after a `room_found` event for the given `room_id`.
- `leave()` is safe from any state and always transitions the local device to
  `IDLE`.
- `session_migrating` is a transient sub-state within `IN_SESSION` in
  `RESILIENT` for surviving peers only.

**Host path:**
`host()` transitions to `HOSTING`. On success, `hosted` transitions to
`IN_SESSION`. On failure, an `error` event transitions back to `IDLE`.

**Client path:**
`join()` transitions to `CONNECTING`. On success, `joined` transitions to
`IN_SESSION`. On failure, an `error` event transitions back to `IDLE`.

---

## 5. Transport Profiles

Transport profiles are declared by the host and communicated to clients in
discovery metadata. A client reads the profile from `room_found` before
deciding to join.

---

### `ble.TRANSPORT.RELIABLE`

**Topology:** GATT star. One Peripheral (host), N Centrals (clients).
**Mechanism:** Clients connect to the host over BLE GATT. Client-to-client
messages are routed through the host.
**Delivery:** Acknowledged at the radio link layer. Automatic retransmit occurs
before failure surfaces to application code.
**Payload ceiling:** Evaluated after bridge serialization. Safe at ~180 bytes.
Up to ~500 bytes after successful MTU negotiation.
**Private messaging:** Supported.
**Host:** Single point of failure. If the host leaves or disappears, the
session ends.

Best for: games that need reliable delivery with the simplest implementation
path.

Limitations: session continuity depends on the host. Connection setup adds
50–500ms before first message. Safe cross-device target is 4 clients.

---

### `ble.TRANSPORT.RESILIENT`

**Topology:** GATT star with graceful host handoff.
**Mechanism:** Identical to `RELIABLE` during normal operation. When the host
calls `leave()`, it selects a successor from the current roster, emits a
handoff control message, disconnects, and the remaining peers reconnect to the
new host under the same `session_id`.
**Delivery:** Same as `RELIABLE`.
**Payload ceiling:** Same as `RELIABLE`.
**Private messaging:** Supported.
**Host:** May change after a graceful migration.
**Migration window:** Typically 1–3 seconds after a clean host departure.

Best for: longer sessions where a planned host departure should not end the
game.

Limitations: only graceful migration is supported. If the host disappears
unexpectedly, the session ends. iOS screen lock on either the current host or
the selected successor can still terminate the session.

**Successor selection:**
The current host is the source of truth for the roster and selects the next
host before disconnecting. The default rule is deterministic: choose the
lowest lexicographic `peer_id` among currently connected clients.

---

### Profile Compatibility

Transport profile is non-negotiable. If a discovered room advertises a profile
the local device cannot support, `join()` fails with
`"transport_unavailable"`.

---

## 6. API Reference

---

### `ble.state()`

Returns the current BLE radio state, independent of session state.

**Returns:** `string`

| Value | Meaning |
|---|---|
| `"on"` | Radio available and ready |
| `"off"` | Radio disabled by user |
| `"unauthorized"` | App lacks Bluetooth permission |
| `"unsupported"` | Device has no BLE hardware |

Listen for `radio` events to react to hardware changes at runtime.

---

### `ble.host(options)`

Begins advertising a hosted session. Transitions to `HOSTING`. On success,
emits `hosted` and enters `IN_SESSION`.

**Parameters:**

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `room` | string | yes | — | Display name shown in discovery. Max 20 characters. |
| `max` | number | yes | — | Maximum connected clients excluding host. Range 1–7. Safe cross-device maximum is 4. |
| `transport` | ble.TRANSPORT | no | `RELIABLE` | Transport profile for this session. |
| `session_id` | string | no | auto | Stable session identifier. Reserved for internal migration use. Do not set manually. |

**Events emitted:**
- `hosted` — advertising started and the local host session is live
- `peer_joined` — a remote peer joined after hosting started
- `peer_left` — a remote peer left after joining
- `error` — hosting failed to start

**Notes:**
- Calling `host()` outside `IDLE` has no effect.
- When `max` clients are already connected, additional join attempts are
  rejected. Existing peers receive no event. The joining device receives
  `error` with code `"room_full"`.

---

### `ble.scan()`

Begins discovering nearby hosted sessions. Does not establish a connection.
Transitions to `SCANNING`.

**Events emitted:**
- `room_found` — a hosted session was discovered
- `room_lost` — a previously discovered room is no longer visible
- `error` — scanning failed to start

**Notes:**
- Calling `scan()` outside `IDLE` has no effect.
- Scanning stops automatically when `join()` is called or when `leave()` is
  called locally.
- Room discovery may lag 1–3 seconds on first scan due to platform duty
  cycling.

---

### `ble.join(room_id)`

Initiates a connection to a discovered room. Stops scanning as a side effect
and transitions to `CONNECTING`.

**Parameters:**

| Field | Type | Description |
|---|---|---|
| `room_id` | string | The `room_id` from a prior `room_found` event. |

**Events emitted:**
- `joined` — successful connection and session entry
- `error` — connection failed or room is no longer available

**Notes:**
- `room_id` values are only valid within the current scan session.
- Calling `join()` without a matching prior `room_found` produces
  `error` with code `"join_failed"`.

---

### `ble.leave()`

Terminates local participation and returns the local device to `IDLE`. Safe to
call when already idle.

**Behavior by state:**

- `HOSTING`, `SCANNING`, `CONNECTING` — local work is canceled and the device
  returns to `IDLE`.
- `IN_SESSION`, client — disconnects from the host and returns locally to
  `IDLE`.
- `IN_SESSION`, host / `RELIABLE` — terminates the session for all clients and
  returns locally to `IDLE`.
- `IN_SESSION`, host / `RESILIENT` — initiates graceful handoff, returns
  locally to `IDLE`, and surviving peers either resume or receive
  `session_ended`.

**Notes:**
- The local device does not receive `peer_left` or `session_ended` for its own
  `leave()`. Session teardown for the caller is complete once `leave()`
  returns.
- On abrupt local loss of radio, the local device receives `session_ended`
  before the `radio` event if it was previously in session.

---

### `ble.broadcast(msg_type, payload)`

Sends a message to all peers in the current session.

**Routing:**
- Host — delivered directly to each connected client
- Client — delivered to host, which relays to all other clients

**Parameters:**

| Field | Type | Description |
|---|---|---|
| `msg_type` | string | Application-defined message identifier. Max 32 characters. |
| `payload` | supported Lua value | Application data. The bridge serializes it internally. |

**Events emitted on failure:**
- `error` with code `"invalid_payload"` — payload type is unsupported
- `error` with code `"payload_too_large"` — serialized payload exceeded transport ceiling
- `error` with code `"send_failed"` — message could not be queued

**Notes:**
- Calling `broadcast()` with no active session is silently ignored.

---

### `ble.send(peer_id, msg_type, payload)`

Sends a message to a single peer.

**Parameters:**

| Field | Type | Description |
|---|---|---|
| `peer_id` | string | Target peer. Must be in the current `ble.peers()` list. |
| `msg_type` | string | Same as `broadcast()`. |
| `payload` | supported Lua value | Same as `broadcast()`. |

**Notes:**
- Sending to an unknown or disconnected `peer_id` is silently ignored.
- Client-to-client targeting is routed through the host transparently.

---

### `ble.poll()`

Drains the incoming event queue and returns all pending events as an ordered
array. Must be called once per frame from `love.update()`.

**Returns:** `table` — array of event tables. May be empty. Never nil.
Never blocks.

**Notes:**
- Call exactly once per frame. The queue is drained fully on each call.
- Events are ordered by arrival time. Process in order.
- This is the only mechanism for receiving data or state changes from the
  native layer.

---

### `ble.local_id()`

Returns this device's `peer_id` within the current session.

**Returns:** `string` — empty string if not in session.

---

### `ble.is_host()`

Returns whether this device is currently the active host.

**Returns:** `boolean`

**Notes:**
- In `RESILIENT`, this may change after `session_resumed`.
- Prefer this for UI or diagnostics, not gameplay decisions.

---

### `ble.peers()`

Returns the current peer roster excluding the local device.

**Returns:** `table` — array of peer tables:

| Field | Type | Description |
|---|---|---|
| `peer_id` | string | Stable identifier for this session |
| `is_host` | boolean | Whether this peer is currently the active host |

**Notes:**
- Returns empty table if not in session.
- The local device is excluded. Use `ble.local_id()` for self.

---

## 7. Events Reference

All events are returned from `ble.poll()` as tables with at minimum a `type`
field. All fields listed are always present unless marked optional.

---

### `room_found`

A hosted session was discovered nearby during scanning.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"room_found"` |
| `room_id` | string | Opaque connection handle. Pass to `join()`. Valid only for the current scan session. |
| `session_id` | string | Stable session identity. |
| `name` | string | Display name set by the host. |
| `transport` | string | `"reliable"` or `"resilient"` |
| `peer_count` | number | Current connected clients excluding host. |
| `max` | number | Session capacity set by host. |
| `rssi` | number | Signal strength in dBm. |

---

### `room_lost`

A previously discovered room is no longer visible.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"room_lost"` |
| `room_id` | string | Matches the corresponding `room_found.room_id`. |

---

### `hosted`

The local device successfully started hosting and entered the session.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"hosted"` |
| `session_id` | string | Stable session identifier. |
| `peer_id` | string | Local host peer ID. Same as `ble.local_id()`. |
| `transport` | string | Active transport profile. |
| `peers` | table | Current roster excluding the local host. Same format as `ble.peers()`. |

---

### `joined`

The local device successfully joined a hosted session and entered
`IN_SESSION`.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"joined"` |
| `session_id` | string | Stable session identifier. |
| `room_id` | string | The room that was joined. |
| `peer_id` | string | Local peer ID. Same as `ble.local_id()`. |
| `host_id` | string | `peer_id` of the current host. |
| `peers` | table | Current roster excluding the local device. Same format as `ble.peers()`. |
| `transport` | string | Active transport profile. |

---

### `peer_joined`

A new remote peer joined the session. Emitted to all peers already in the
session.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"peer_joined"` |
| `peer_id` | string | The newly connected peer. |
| `peers` | table | Updated roster excluding the local device. |

---

### `peer_left`

A remote peer disconnected or timed out. Emitted to surviving peers only.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"peer_left"` |
| `peer_id` | string | The peer that left. |
| `reason` | string | See reasons below. |
| `peers` | table | Updated roster excluding the local device. |

**Reasons:**

| Value | Meaning |
|---|---|
| `"left"` | Clean disconnect initiated by that peer |
| `"timeout"` | Connection was lost unexpectedly |

---

### `message`

A message was received from a peer.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"message"` |
| `peer_id` | string | Sender peer ID. |
| `msg_type` | string | Application-defined type. |
| `payload` | supported Lua value | Decoded application payload. |

---

### `session_migrating`

The current host initiated a graceful handoff. The session is temporarily
paused. Emitted to surviving peers only in `RESILIENT`.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"session_migrating"` |
| `old_host_id` | string | The peer ID of the departing host. |
| `new_host_id` | string | The selected successor. |

---

### `session_resumed`

Graceful migration completed and the session is live again. Emitted to
surviving peers only in `RESILIENT`.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"session_resumed"` |
| `new_host_id` | string | The peer now hosting the session. |
| `session_id` | string | Unchanged from before migration. |
| `peers` | table | Updated roster excluding the local device. |

---

### `session_ended`

The session terminated with no recovery path. Transitions the local device to
`IDLE`.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"session_ended"` |
| `reason` | string | See reasons below. |

**Reasons:**

| Value | Meaning |
|---|---|
| `"host_left"` | Host ended the session in `RELIABLE` |
| `"host_lost"` | Host connection was lost unexpectedly |
| `"migration_failed"` | Graceful handoff in `RESILIENT` did not complete |
| `"radio_off"` | Local Bluetooth became unavailable during session |

---

### `radio`

The BLE hardware state changed.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"radio"` |
| `state` | string | New hardware state. Same values as `ble.state()`. |

**Notes:**
- If `state` is `"off"` during an active session, `session_ended` with reason
  `"radio_off"` precedes it in the same `poll()` result.

---

### `error`

An operation failed.

| Field | Type | Description |
|---|---|---|
| `type` | string | `"error"` |
| `code` | string | Machine-readable error code. |
| `detail` | string | Human-readable detail for logs. |

---

## 8. Error Codes

All operation failures arrive as events of type `"error"`.

| Code | Trigger |
|---|---|
| `"host_failed"` | `host()` could not start advertising |
| `"scan_failed"` | `scan()` could not start |
| `"join_failed"` | `join()` connection attempt failed |
| `"room_gone"` | Room disappeared between `room_found` and `join()` |
| `"room_full"` | Room reached capacity before join completed |
| `"transport_unavailable"` | The room's transport is unsupported on this device |
| `"invalid_payload"` | Payload contains unsupported Lua types or cyclic tables |
| `"payload_too_large"` | Serialized payload exceeded transport ceiling |
| `"send_failed"` | Message could not be queued |
| `"mtu_failed"` | MTU negotiation failed; safe payload ceiling is reduced |

---

## 9. Constraints and Limits

### Hard Limits

| Constraint | Value | Notes |
|---|---|---|
| Max clients per session | 7 | OS and hardware dependent. 4 is the safe cross-device target. |
| Max room name length | 20 characters | Must fit in discovery metadata. |
| Max `msg_type` length | 32 characters | |
| `RELIABLE` / `RESILIENT` safe serialized payload | ~180 bytes | Before successful MTU negotiation is confirmed. |
| `RELIABLE` / `RESILIENT` max serialized payload | ~500 bytes | After successful MTU negotiation. |

### Operational Limits

| Constraint | Typical Value | Notes |
|---|---|---|
| Effective range | ~10m indoors | Walls and interference reduce this. |
| Discovery latency | 1–3 seconds | First `room_found` after `scan()`. |
| Connection setup | 50–500ms | Time from `join()` to `joined`. |
| Message latency | 10–50ms | One hop in foreground conditions. |
| Migration window | 1–3 seconds | Graceful handoff in `RESILIENT`. |

### Platform Constraints

**iOS:**
- Peripheral role is suspended when the app is backgrounded. A host that locks
  the screen can terminate the session.
- MAC addresses are not exposed. Session identity must rely on `peer_id`.
- Graceful migration still depends on the chosen successor remaining in the
  foreground and keeping Bluetooth available.

**Android:**
- BLE behavior varies by OEM and OS version. Background process management can
  degrade advertising and scanning reliability.
- For maximum compatibility, design for a BLE 4.2 baseline even when newer
  hardware supports larger MTUs or better timing.

---

## 10. Native Bridge Contract

The Lua module is a thin wrapper over a native C library exposed via FFI. The
Lua-facing API deals in ordinary Lua values. The bridge is responsible for
converting those values to and from a compact internal wire representation.

### C API

```c
// Radio state. Returns: "on" | "off" | "unauthorized" | "unsupported"
const char* ble_state(void);

// Session control. All return immediately.
void ble_host(const char* options_json);
void ble_scan(void);
void ble_join(const char* room_id);
void ble_leave(void);

// Messaging. Payload is a JSON value produced by the Lua wrapper.
void ble_broadcast(const char* msg_type, const char* payload_json);
void ble_send(const char* peer_id, const char* msg_type,
              const char* payload_json);

// Queue drain. Returns JSON array of event objects.
// Caller owns returned string. Call ble_free_str() after use.
const char* ble_poll(void);
void        ble_free_str(const char* s);

// Session inspection. All synchronous.
const char* ble_local_id(void);
int         ble_is_host(void);

// Returns JSON array of peer objects.
// Caller owns returned string. Call ble_free_str() after use.
const char* ble_peers(void);
```

### Threading Model

The native layer owns one or more OS-managed BLE threads. OS callbacks are
handled there and converted into queued events. `ble_poll()` drains that queue
from the Lua thread. Lua never blocks on a BLE operation.

### Serialization

`ble_host()` accepts a JSON object. `ble_broadcast()` and `ble_send()` accept
JSON values representing application payloads. `ble_poll()` and `ble_peers()`
return JSON data for the Lua wrapper to decode into ordinary Lua tables.

Application code never performs wire encoding. The bridge serializes payloads
internally before transmission and decodes them before surfacing a `message`
event.

Supported payload types:

- `boolean`
- `number`
- `string`
- array-like tables
- map-like tables with string keys
- nested combinations of the above

Unsupported payload forms:

- functions
- userdata
- threads
- cyclic tables
- mixed array/map tables

If a payload cannot be serialized, the send operation emits `error` with code
`"invalid_payload"`.

---

## 11. Usage Patterns

### Minimal Setup

```lua
local ble = require("ble")

function love.update(dt)
  for _, ev in ipairs(ble.poll()) do
    handle_event(ev)
  end
end

function handle_event(ev)
  if ev.type == "hosted" then
    scene.enter_lobby(ev.session_id)

  elseif ev.type == "joined" then
    scene.enter_lobby(ev.session_id)

  elseif ev.type == "peer_joined" or ev.type == "peer_left" then
    lobby.set_roster(ev.peers)

  elseif ev.type == "message" then
    game.handle_network(ev.msg_type, ev.peer_id, ev.payload)

  elseif ev.type == "session_ended" then
    scene.enter_main_menu()

  elseif ev.type == "radio" and ev.state == "off" then
    ui.show("Bluetooth is off")
  end
end
```

---

### Hosting a Session

```lua
ble.host({
  room      = "Ivan's Game",
  max       = 3,
  transport = ble.TRANSPORT.RESILIENT,
})
```

---

### Scanning and Joining

```lua
ble.scan()

if ev.type == "room_found" then
  show_room(ev.room_id, ev.name, ev.peer_count, ev.max, ev.transport)
end

if ev.type == "room_lost" then
  remove_room(ev.room_id)
end

ble.join(selected_room_id)

if ev.type == "joined" then
  switch_scene("lobby")
end
```

---

### Sending Game State

```lua
local function submit_move(action, target)
  ble.broadcast("move", {
    action = action,
    target = target,
  })
end

local function send_hand(peer_id, cards)
  ble.send(peer_id, "deal", {
    cards = cards,
  })
end

if ev.type == "message" then
  if ev.msg_type == "move" then
    game.apply_move(ev.peer_id, ev.payload)
  elseif ev.msg_type == "deal" then
    player.set_hand(ev.payload.cards)
  end
end
```

---

### Handling Migration

```lua
if ev.type == "session_migrating" then
  ui.show("Host left. Reconnecting...")

elseif ev.type == "session_resumed" then
  ui.hide_overlay()
  lobby.set_roster(ev.peers)

elseif ev.type == "session_ended" then
  if ev.reason == "migration_failed" or ev.reason == "host_lost" then
    ui.show("Session ended.")
  end
  switch_scene("main_menu")
end
```

---

### Choosing a Transport Profile

```lua
-- Standard game, reliable delivery, simplest implementation path
ble.host({ room = "My Game",   max = 4, transport = ble.TRANSPORT.RELIABLE })

-- Long session, planned host departure should not end the game
ble.host({ room = "Long Game", max = 4, transport = ble.TRANSPORT.RESILIENT })
```

---

*End of specification.*
