# BLE Game Network

## Project

This repo contains a BLE communication layer for LÖVE.

BLE means Bluetooth Low Energy: short-range wireless communication between nearby devices without relying on the internet.

In a game, you use it to host nearby rooms, discover them, join sessions, and exchange gameplay messages through `lua/ble_net` on top of patched native LÖVE builds.

Transport modes:

- `Normal`: one host, multiple clients. Messages go through the host. If the host leaves or disappears, the session ends.
- `Resilient`: if the host disconnects unexpectedly, the remaining peers elect a deterministic successor, reconnect under the same session id, and continue if recovery succeeds.

Recovery notes:

- `Normal` keeps the current stable behavior.
- `Resilient` needs at least one other peer still connected to recover.
- the transport restores the session; each game is responsible for re-broadcasting its shared state after resume.

It includes:

- native BLE bridge work in the external vendor repos:
  - `love`
  - `love-android`
- reusable Lua-side integration code in `lua/ble_net`
- demo projects used to test and package the current implementation:
  - `demo-chat`
  - `demo-tictactoe`

## How To Use

### Simple API

Lua-side controller:

```lua
local ble_net = require("ble_net")

local network = ble_net.new({
  title = "My Game",
  room_name = "Room",
  max_clients = 4,
})

network.initialize()
network.update()
network.start_host(ble_net.TRANSPORT.NORMAL)
network.start_scan()
network.join_room(room_id, room_name)
network.leave_session()
network.broadcast_payload("event_name", payload)
network.send_payload(peer_id, "event_name", payload)
network.set_event_handler(function(ev, net, state)
  -- game-specific event handling
end)
```

Useful controller state:

- `network.state.rooms`
- `network.state.peers`
- `network.state.session_id`
- `network.state.in_session`
- `network.state.is_host`
- `network.state.local_id`
- `network.state.status`
- `network.state.diagnostics`

Underlying native `love.ble` surface used by `ble_net`:

```lua
love.ble.state()
love.ble.host(options)
love.ble.scan()
love.ble.join(room_id)
love.ble.leave()
love.ble.broadcast(msg_type, payload)
love.ble.send(peer_id, msg_type, payload)
love.ble.poll()
love.ble.local_id()
love.ble.is_host()
love.ble.peers()
```

`ble_net.TRANSPORT.NORMAL` maps to the current native reliable mode. `ble_net.TRANSPORT.RELIABLE` still exists as a compatibility alias.

Main event types returned through polling / `ble_net`:

- `room_found`
- `room_lost`
- `hosted`
- `joined`
- `peer_joined`
- `peer_left`
- `message`
- `session_migrating`
- `session_resumed`
- `session_ended`
- `radio`
- `error`
- `diagnostic`

## How To Build And Install

### Vendor Setup

Apply the native BLE patches to the vendor repos:

```bash
./scripts/apply-vendor-patches.sh
```

Normal native development happens in:

- `love`
- `love-android`

When Android native engine files change in `love`, sync the vendored Android engine copy:

```bash
./scripts/sync-android-vendor-love.sh
```

When you want to freeze the current native state back into patch files:

```bash
./scripts/export-vendor-patches.sh
```

### iOS

Build and deploy the current demos to iOS:

```bash
./deploy-demo-ios.sh --device <DEVICE_ID>
```

The script:

- builds the `love-ios` app
- packages every `demo-*` project as a `.love`
- copies those demos into the app Documents folder
- lets the LOVE project selector choose which demo to run

### Android

Build and deploy the current demos to Android:

```bash
./deploy-demo-android.sh --serial <SERIAL>
```

The script:

- builds the Android LOVE launcher
- packages every `demo-*` project as a `.love`
- copies those demos into the app games folder
- lets the LOVE launcher list and open them

### Vendor Patch Bases

Current frozen patch bases:

- `love`: `ab8dfaa1da571d6ebb09ff1fccb91e5039fce7a0`
- `love-android`: `007d258cb477e51a08229f3d35179966da6e22d3`
- `love-android/app/src/main/cpp/love`: `5670df13b6980afd025cd7e7d442a24499bf86a7`
