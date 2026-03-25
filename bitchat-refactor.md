# Bitchat Refactor Plan

This document defines how to use the local `bitchat/bitchat` codebase as a reference for improving this repo's BLE communication layer.

The goal is not to turn this project into a clone of `bitchat`, and it is not to optimize specifically for chat.

The goal is to improve this repo as a generic BLE communication layer for games built with LÖVE.

## Core Objective

The reusable product in this repo is:
- a patched native BLE runtime for LÖVE on iOS and Android
- a reusable Lua communication layer in `lua/ble_net`

That layer must support game communication primitives, not just chat.

Examples of intended use:
- room discovery
- session join / leave
- player presence
- reliable game events
- state sync messages
- control packets
- arbitrary payload delivery for gameplay systems

`demo-chat` remains only an example consumer and test harness.

## Constraints

### Keep Generic Game Use Intact

Any borrowed structure from `bitchat` must be evaluated against a generic game networking use case.

We should avoid designs that assume:
- human chat is the primary payload
- text message history is the main domain model
- Nostr, relay, mesh gossip, or social identity are required

### Keep Native Scope Narrow

Native changes in `love/` and `love-android/` must stay limited to BLE bridge work.

That includes:
- packet encoding / decoding
- fragment assembly
- validation
- connection / session safety
- diagnostics

It does not include non-BLE feature work.

### Keep Lua as the Public Integration Layer

Downstream users should integrate through:
- patched native builds
- `lua/ble_net`

They should not need to reuse `demo-chat` or copy app-specific UI.

## What Bitchat Is Useful For

`bitchat` is useful here as a reference for:
- transport limits and shared constants
- validation boundaries
- defensive packet parsing
- bounded fragment / stream assembly
- deduplication utilities
- sender binding and connection trust checks
- error handling and reset behavior

`bitchat` is not the right model here for:
- app architecture as a whole
- chat-first domain modeling
- Nostr integration
- relay routing
- mesh gossip and store-and-forward logic
- full service object structure

## What We Should Borrow

### 1. Centralized Transport Configuration

Reference:
- `bitchat/bitchat/Services/TransportConfig.swift`

We should centralize:
- packet size limits
- fragment count limits
- buffer limits
- stale assembly timeouts
- dedup windows
- retry / watchdog timings

Target in this repo:
- `lua/ble_net/config.lua`
- mirrored native limits in the BLE bridge where needed

Why:
- our current limits are spread across Lua, iOS, and Android implementations
- centralizing them makes behavior easier to reason about and keep aligned

### 2. Dedicated Validation Layer

References:
- `bitchat/bitchat/Utils/InputValidator.swift`
- `bitchat/bitchat/Protocols/BinaryProtocol.swift`

We should introduce validation helpers for:
- room metadata
- session ids
- peer ids
- message kinds / control types
- payload sizes
- fragment ordering
- fragment count consistency
- malformed or truncated packets

Target in this repo:
- `lua/ble_net/validation.lua`
- native validation helpers inside BLE bridge code

Why:
- our validation is currently embedded inside handlers and decode paths
- explicit validation improves safety, error reporting, and testability

### 3. Bounded Dedup Utilities

References:
- `bitchat/bitchat/Utils/MessageDeduplicator.swift`
- `bitchat/bitchat/Services/MessageDeduplicationService.swift`

We should add small reusable dedup helpers for:
- repeated incoming packets
- repeated control messages
- duplicate room announcements
- duplicate join / handshake flows

Target in this repo:
- `lua/ble_net/dedup.lua`
- native dedup where packet processing needs it

Why:
- dedup should be a deliberate utility, not scattered guard logic

### 4. Safer Fragment Assembly

Reference:
- `bitchat/bitchat/Services/NotificationStreamAssembler.swift`

We should borrow the defensive ideas, not the exact implementation:
- bounded buffers
- stale assembly cleanup
- malformed sequence rejection
- reset on unrecoverable assembly state
- useful diagnostics around dropped or invalid input

Target in this repo:
- native BLE fragment assembly paths on iOS and Android

Why:
- this is a transport concern and fits our generic communication layer
- games need reliable failure behavior more than clever recovery

### 5. Sender Binding and Connection Trust

Reference:
- `bitchat/bitchat/Services/BLE/BLEService.swift`

We should bind a logical sender identity to the first trusted BLE link for a session and reject mismatches afterward.

That means:
- a connection should not be able to impersonate arbitrary sender ids
- host and client paths should validate that packet sender fields match the bound peer / connection state

Target in this repo:
- native BLE receive paths
- session join / hello handling

Why:
- this is one of the strongest correctness and safety upgrades available from `bitchat`

## What We Should Not Borrow

Do not copy these into the core design:
- `MessageRouter` as-is
- Nostr transport abstractions
- relay / gossip / mesh routing
- chat-centric persistence
- social identity / verification workflows
- file transfer pipeline
- the `BLEService.swift` god object structure

Reason:
- these solve a broader and different product problem than ours
- they would distort this repo away from a reusable game communication layer

## Proposed Refactor Shape

### Lua Layer

Target structure:

```text
lua/
  ble_net/
    init.lua
    config.lua
    validation.lua
    dedup.lua
```

Responsibilities:

- `init.lua`
  - public controller API
  - session lifecycle
  - polling / event translation
  - generic high-level actions

- `config.lua`
  - shared limits and timing constants

- `validation.lua`
  - generic payload and metadata validation

- `dedup.lua`
  - bounded caches for duplicate suppression

### Native BLE Layer

Keep the current platform split, but improve internal separation:

- packet codec
- fragment assembler
- validation
- sender binding
- connection / join lifecycle
- diagnostics

This is an internal separation goal, not necessarily a file split goal in the first pass.

## Public API Direction

The Lua layer should stay game-oriented and generic.

Prefer a surface like:

```lua
local ble_net = require("ble_net")

ble_net.host(opts)
ble_net.scan()
ble_net.join(room_id)
ble_net.leave()
ble_net.send(kind, payload, opts)
ble_net.update()
ble_net.poll()
```

Important:
- `send` should not be chat-specific
- control packets and gameplay payloads should be first-class
- chat remains just one possible consumer of the transport

## Two-Step Upgrade Plan

## Step 1: Reorganize Based on Bitchat's Useful Structure

This step changes organization and boundaries before copying more behavior.

Tasks:
- create `lua/ble_net/config.lua`
- create `lua/ble_net/validation.lua`
- create `lua/ble_net/dedup.lua`
- move generic limits out of ad hoc locations into config
- move generic validation into dedicated helpers
- move duplicate suppression into dedicated helpers
- identify native points where sender binding and fragment safety should be enforced

Deliverable:
- a cleaner internal structure without changing the public purpose of the library

Success condition:
- `ble_net` becomes easier to extend for non-chat game communication

## Step 2: Copy and Adapt the Useful Parts

This step ports useful behavior patterns from `bitchat` into our implementation.

Tasks:
- port defensive validation ideas
- port bounded dedup logic
- port fragment reset / timeout safeguards
- port sender-binding checks
- improve malformed payload diagnostics
- improve error handling on invalid or partial packet flows

Rules:
- adapt to our protocol instead of translating blindly
- preserve our room/session model
- preserve our generic game communication goal
- do not import Nostr or chat-specific logic

Deliverable:
- stronger validation and error handling on both native and Lua paths

Success condition:
- malformed or inconsistent BLE traffic fails clearly and safely
- duplicate or spoofed traffic is handled intentionally
- the library remains reusable outside chat

## Practical Acceptance Criteria

After this refactor direction is complete, we should have:

- a downstream-usable Lua layer that is not tied to chat UI
- centralized limits and validation rules
- explicit duplicate suppression behavior
- safer connection-to-sender trust handling
- clearer diagnostics for invalid packets and assemblies
- no Nostr or chat-first architecture leaking into the core transport

## Immediate Next Work

Recommended order:

1. Add `lua/ble_net/config.lua`
2. Add `lua/ble_net/validation.lua`
3. Add `lua/ble_net/dedup.lua`
4. Wire Lua controller code to use them
5. Apply sender-binding and fragment-safety upgrades in native BLE code
6. Add focused tests / diagnostics around malformed traffic and duplicate flows

## Guiding Principle

Use `bitchat` as a source of transport discipline.

Do not use `bitchat` as the product definition.

Our product is a reusable BLE communication layer for games.
