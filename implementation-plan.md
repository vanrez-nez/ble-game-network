# BLE Implementation Plan

This document turns [specification.md](specification.md) into a concrete implementation plan across the cloned LÖVE repositories in this workspace.

## Scope

Deliverables:

- `love.ble` native module in the LÖVE engine
- Android backend using Android BLE GATT
- iOS backend using CoreBluetooth
- desktop stub backend that reports `"unsupported"`
- small chat demo built against the public Lua API

Non-goals for the first pass:

- background-mode reliability beyond the current spec
- unexpected-host-loss recovery in `RESILIENT`
- encryption, pairing UX, or Internet fallback

## Repository Ownership

### `love`

Owns the public Lua API, core state machine, payload serialization contract,
event queue, and platform backends.

Planned additions:

- `love/src/modules/ble/Ble.h`
- `love/src/modules/ble/Ble.cpp`
- `love/src/modules/ble/wrap_Ble.h`
- `love/src/modules/ble/wrap_Ble.cpp`
- `love/src/modules/ble/Codec.h`
- `love/src/modules/ble/Codec.cpp`
- `love/src/modules/ble/sdl/Ble.h`
- `love/src/modules/ble/sdl/Ble.cpp`
- `love/src/modules/ble/android/Ble.h`
- `love/src/modules/ble/android/Ble.cpp`
- `love/src/modules/ble/apple/Ble.h`
- `love/src/modules/ble/apple/Ble.mm`

Planned modifications:

- `love/src/common/config.h`
- `love/src/modules/love/love.cpp`
- `love/CMakeLists.txt`
- `love/platform/xcode/liblove.xcodeproj/project.pbxproj`
- `love/platform/xcode/love.xcodeproj/project.pbxproj`
- `love/platform/xcode/ios/love-ios.plist`

### `love-android`

Owns Android BLE objects, Android lifecycle integration, permission prompts, and
the Java-to-native event bridge.

Planned additions:

- `love-android/app/src/main/java/org/love2d/android/ble/BleManager.java`

Planned modifications:

- `love-android/app/src/main/java/org/love2d/android/GameActivity.java`
- `love-android/app/src/main/AndroidManifest.xml`

### `love-apple-dependencies`

No change is planned for the first pass. CoreBluetooth is a system framework,
not an external dependency. Only revisit this repo if we later add a third-party
binary codec or iOS helper library.

## Engine Architecture

### Public Lua Module

Expose `love.ble` as a first-class engine module, parallel to
`love.sensor` and `love.system`.

Public Lua functions:

- `love.ble.state()`
- `love.ble.host(options)`
- `love.ble.scan()`
- `love.ble.join(room_id)`
- `love.ble.leave()`
- `love.ble.broadcast(msg_type, payload)`
- `love.ble.send(peer_id, msg_type, payload)`
- `love.ble.poll()`
- `love.ble.localId()`
- `love.ble.isHost()`
- `love.ble.peers()`

Constants:

- `love.ble.TRANSPORT.RELIABLE`
- `love.ble.TRANSPORT.RESILIENT`

Naming note:

- The spec uses `ble.local_id()` and `ble.is_host()`.
- The engine should follow existing LÖVE casing conventions in Lua and export
  `localId` and `isHost`.
- If strict spec parity matters, aliases can be provided.

### Core C++ Module Shape

Model it after existing root-plus-backend modules in `love/CMakeLists.txt`.

Core types in `Ble.h`:

- `RadioState`
- `Transport`
- `PeerInfo`
- `Event`
- `Ble` abstract module class

Backend responsibilities:

- start and stop advertising
- scan and track discovered rooms
- connect and disconnect peers
- negotiate MTU where available
- send and receive framed payload bytes
- report platform permission and radio changes back to the core module

Core module responsibilities:

- enforce the public state machine
- reject invalid API calls by state
- serialize Lua payloads into an internal payload form
- deserialize incoming payloads back to Lua values
- maintain the ordered event queue exposed via `poll()`
- own the public event contract exposed to Lua
- own roster snapshots for `hosted`, `joined`, `peer_joined`, `peer_left`,
  `session_migrating`, and `session_resumed`

Ownership split:

- platform backends own platform BLE objects and connection-local state
- platform backends may cache room ids, peer ids, GATT objects, and transient
  routing state needed to drive BLE correctly
- the core C++ module owns the public API contract, event marshaling to Lua,
  and canonical payload codec
- Java on Android and Objective-C++ on iOS must not invent extra public states
  outside the spec; they report platform facts upward and the module surfaces
  them as spec events

### Payload Representation

Do not add a new third-party serialization dependency in v1.

Use existing LÖVE `Variant` support as the Lua-facing payload model:

- `boolean`
- `number`
- `string`
- array-like tables
- map-like tables with string keys

Implementation plan:

- `wrap_Ble.cpp` converts Lua values to `love::Variant`
- `Codec.cpp` encodes `Variant` into a canonical internal byte buffer
- backend transports framed bytes over BLE
- received frames are decoded back into `Variant`
- `wrap_Ble.cpp` pushes `Variant` back into Lua on `message.payload`

Why this approach:

- no dependency changes in `love-apple-dependencies`
- no JSON round-trip in gameplay code
- consistent validation path for `"invalid_payload"`

Concrete codec requirements:

- supported value kinds:
  - `nil`
  - `boolean`
  - `number`
  - `string`
  - array-like tables
  - map-like tables with string keys
- rejected payloads:
  - userdata
  - functions
  - threads
  - cyclic tables
  - mixed array-plus-map tables unless canonicalized explicitly
- deterministic encoding is required so Android and iOS can exchange payloads
  without platform-specific logic
- the codec must expose size-before-send so backends can raise
  `"payload_too_large"` before writing to BLE

Concrete wire frame requirements:

- one transport frame type for control messages
- one transport frame type for application data messages
- header fields:
  - protocol version
  - frame kind
  - sender peer id
  - target peer id or empty for broadcast
  - message type
  - payload length
- payload body is the codec output, not raw Lua strings
- if a frame exceeds the safe BLE write size, the backend fragments and
  reassembles below the codec layer
- fragmentation metadata must include:
  - message nonce
  - fragment index
  - fragment count

Safe transport ceilings:

- unfragmented writes should target the pre-MTU safe ceiling from the spec
- larger frames may be sent only after MTU negotiation succeeds
- if fragmentation is not available on a backend yet, it must emit
  `"payload_too_large"` instead of silently truncating

### Event Queue

For the first pass, keep the queue inside the `Ble` module unless extraction is
needed by code size or tests.

Requirements:

- multi-producer, single-consumer
- safe from platform BLE callback threads
- preserves enqueue order
- drained fully by `love.ble.poll()`

Recommended implementation:

- `std::mutex`
- `std::deque<Event>`
- short critical sections

The event rate is small enough that a simple queue is preferable to a lock-free
structure for the first pass.

## Build Integration

### `love/CMakeLists.txt`

Add a new section parallel to `love.sensor`:

- `love_ble_root`
- `love_ble_<platform>`
- `love_ble`

Linking plan:

- `love_ble_root` links `lovedep::Lua`
- Android backend links JNI and platform glue already available in the Android
  target
- desktop backend compiles a stub implementation
- `liblove` links `love_ble`

### Build Reproducibility

Android:

- `love-android` requires initialized submodules before any Java or native build
- document `git submodule sync --recursive`
- document `git submodule update --init --force --recursive`
- default developer build target for the demo is `:app:assembleEmbedNoRecordDebug`

iOS:

- the first pass targets real devices, not the iOS simulator
- simulator BLE testing is out of scope unless proven workable later
- Xcode signing and provisioning remain developer-machine concerns, but the
  project files must build after the BLE sources and framework are added

### `love/src/common/config.h`

Add:

- `LOVE_ENABLE_BLE`

### `love/src/modules/love/love.cpp`

Add:

- `extern int luaopen_love_ble(lua_State *);`
- module registration entry `{ "love.ble", luaopen_love_ble }`

## Android Plan

### Permissions

Update `love-android/app/src/main/AndroidManifest.xml` with modern BLE support:

- `android.permission.BLUETOOTH`
- `android.permission.BLUETOOTH_ADMIN`
- `android.permission.BLUETOOTH_SCAN`
- `android.permission.BLUETOOTH_CONNECT`
- `android.permission.BLUETOOTH_ADVERTISE`
- `android.permission.ACCESS_FINE_LOCATION` with `maxSdkVersion="30"`
- `android.hardware.bluetooth_le` feature with `required="false"`

Runtime permission flow in `GameActivity.java`:

- `hasBluetoothPermissions()`
- `requestBluetoothPermissions()`
- request `SCAN`, `CONNECT`, and `ADVERTISE` on Android 12+
- request `ACCESS_FINE_LOCATION` on Android 11 and lower for scanning

### Java BLE Manager

Create `org.love2d.android.ble.BleManager` to own:

- `BluetoothManager`
- `BluetoothAdapter`
- `BluetoothLeAdvertiser`
- `BluetoothLeScanner`
- `BluetoothGattServer`
- `BluetoothGatt` client connections
- scan result cache
- connected-peer routing tables
- pending connection-to-peer-id state
- advertisement lifecycle state

JNI-facing methods:

- `host(String room, int maxClients, String transport)`
- `scan()`
- `join(String roomId)`
- `leave()`
- `broadcast(String msgType, byte[] framedPayload)`
- `send(String peerId, String msgType, byte[] framedPayload)`
- `getRadioState()`

Callbacks from Java into native:

- radio state changes
- room discovery and loss
- join success and failure
- peer connect and disconnect
- message receipt
- MTU update results

Concrete Android topology:

- one primary custom service UUID shared across Android and iOS
- one notify/write characteristic for framed session traffic in v1
- one CCC descriptor for notification enablement
- room metadata is advertised in scan response service data using a compact
  string payload:
  - protocol version
  - session id
  - host peer id
  - transport code
  - max clients
  - current peer count
  - truncated room name
- host must not start advertising until `BluetoothGattServerCallback.onServiceAdded`
  confirms the service exists
- scan should use first-match and match-lost callbacks when available so
  `room_found` and `room_lost` share one source of truth

Concrete Android routing model:

- host assigns and publishes peer ids
- clients send all application traffic to the host
- host relays broadcasts to all other clients
- host relays targeted sends only to the addressed client
- host must not surface targeted client-to-client traffic as a local
  application `message` event unless the host is the destination

Concrete Android lifecycle rules:

- `GameActivity` forwards permission and lifecycle events into `BleManager`
- permission waits must never block forever on empty `grantResults`
- `onDestroy` performs a clean `leave()`
- `onPause` and `onResume` are integration points for later radio/foreground
  policy, but v1 remains foreground-oriented

### Native Android Backend

`love/src/modules/ble/android/Ble.cpp` owns:

- JNI registration
- conversion between Java callback payloads and native events
- handoff into the module event queue

Concrete ownership rule:

- Java owns Android BLE objects and transport-local routing state
- C++ owns payload codec integration, Lua-facing values, and event emission
- Java failures must be the single source of truth for operation errors; the C++
  wrapper should not add generic duplicate errors on a `false` return

### Activity Lifecycle

`GameActivity.java` must forward:

- `onCreate`
- `onPause`
- `onResume`
- `onDestroy`
- `onRequestPermissionsResult`

The BLE manager should pause scanning and advertising when the app loses the
foreground if the platform forces it, and surface resulting termination via the
normal event path.

## iOS Plan

### Native Backend

Create `love/src/modules/ble/apple/Ble.mm` using:

- `CBCentralManager`
- `CBPeripheralManager`
- `CBPeripheral`
- `CBMutableService`
- `CBMutableCharacteristic`
- delegate helper objects implementing:
  - `CBCentralManagerDelegate`
  - `CBPeripheralDelegate`
  - `CBPeripheralManagerDelegate`

Responsibilities:

- advertise room metadata in the GATT-discoverable path
- scan for rooms and map discovered peripherals to `room_id`
- host GATT service and characteristics
- connect as central when joining
- route incoming writes and notifications into the event queue

Concrete iOS object model:

- `Ble.mm` owns one Objective-C++ wrapper object retained by the C++ backend
- that wrapper owns:
  - one `CBCentralManager`
  - one `CBPeripheralManager`
  - discovered peripheral map by generated room id
  - connected peripheral map by peer id
  - pending writes / reassembly buffers
- the Objective-C++ layer reports only platform facts to the C++ backend:
  - manager powered state changes
  - room found / room lost
  - hosted
  - joined
  - peer joined / peer left
  - framed message received
  - terminal failures

Concrete iOS topology:

- reuse the same custom service UUID, characteristic UUID, and framing protocol
  as Android
- advertise the same compact room metadata string as Android, truncated to fit
  iOS advertisement limits
- host does not emit `hosted` until `CBPeripheralManager` reports the service is
  published and advertising has started
- join does not emit `joined` until the central has:
  - connected
  - discovered the service
  - discovered the characteristic
  - enabled notifications if required

Concrete iOS constraints:

- plan for stricter advertisement payload budgets than Android
- plan for delegate-driven asynchronous state machines; no blocking waits
- plan for duplicate discovery updates and peripheral identity churn
- v1 remains foreground-only; no Bluetooth background modes are added
- v1 testing target is real iPhone hardware, not simulator

### Xcode Project Changes

Update:

- `love/platform/xcode/liblove.xcodeproj/project.pbxproj`
- `love/platform/xcode/love.xcodeproj/project.pbxproj`

Add:

- BLE source files
- `CoreBluetooth.framework`
- Objective-C++ compile settings for `Ble.mm` if required by the project

### Plist

Update `love/platform/xcode/ios/love-ios.plist`:

- `NSBluetoothAlwaysUsageDescription`

Do not add background Bluetooth modes in the first pass. The spec is explicitly
foreground-oriented.

## Session Semantics

### `RELIABLE`

Implementation shape:

- host exposes one service with framed traffic characteristics
- each client gets a `peer_id` assigned by host after connection
- host is the source of truth for the roster
- host relays broadcast and targeted client messages
- room discovery metadata is advisory; roster truth comes from the host session

### `RESILIENT`

Implement only graceful handoff in v1.

Sequence:

1. Host receives local `leave()`.
2. Host selects successor from current connected clients.
3. Host sends a handoff control frame containing:
   - `session_id`
   - `new_host_id`
   - full roster snapshot
   - migration nonce
4. Surviving peers emit `session_migrating`.
5. New host starts advertising and hosting under the same `session_id`.
6. Other peers reconnect.
7. On success, peers emit `session_resumed`.
8. On timeout, peers emit `session_ended` with `"migration_failed"`.

Do not attempt recovery from abrupt host disappearance in v1.

## Milestones

### M1: Engine Skeleton

- add `love.ble` module shell
- add desktop stub backend returning `"unsupported"`
- wire module into config and loader
- implement Lua payload validation using `Variant`
- define the canonical payload codec and wire frame format
- add unit-style smoke harness where practical

Acceptance:

- `require("love.ble")` succeeds on supported builds
- `state()`, `host()`, `scan()`, `poll()` behave on the stub backend

### M2: Android `RELIABLE`

- add Android permissions and BLE manager
- initialize required submodules as a documented build prerequisite
- implement room discovery
- implement host, join, leave
- implement broadcast and targeted send
- surface radio and error events
- validate service-added before advertise behavior
- validate room loss behavior

Acceptance:

- two Android devices can host, discover, join, exchange chat messages, and
  leave cleanly

### M3: iOS `RELIABLE`

- add CoreBluetooth backend
- add plist and Xcode integration
- implement same message path and roster events as Android
- implement the same payload codec and framed transport as Android
- validate real-device build and run flow

Acceptance:

- Android and iPhone can host and join each other and exchange chat messages

### M4: `RESILIENT`

- implement graceful host handoff
- add timeout handling and resumed events
- test mixed Android/iOS migration

Acceptance:

- host can leave a 3-device session without ending it

### M5: Demo Hardening

- run the chat demo on Android and iOS
- validate payload limits with realistic text messages
- polish permission and radio-off UI
- document the root deployment script and Android build variant

## Test Matrix

Manual tests required:

- Android host -> Android client
- Android host -> iOS client
- iOS host -> Android client
- iOS host -> iOS client
- host leave in `RELIABLE`
- host leave in `RESILIENT`
- radio off during active session
- permission denied on first launch
- oversized payload rejection
- room reaches capacity during join race

## Demo Target

The demo app in [demo-chat](demo-chat) is the vertical slice target.

Definition of done for the demo:

- user can host or join a room
- user sees peer join and leave notices
- user can send chat messages
- messages render with sender identity
- session termination and migration states are visible in UI
- app runs today with the mock backend and later with the real native module
