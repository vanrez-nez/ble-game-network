# Integration Guide

This documents the intended downstream integration model for the BLE bridge.

## What a User Should Consume

A downstream user should not need to copy the entire repo.

They should consume two things:

1. a LÖVE runtime build with the BLE bridge patched in
2. a reusable Lua package from `lua/ble_net`

## Native Requirement

The BLE functionality depends on native engine support.

That means downstream users need:
- patched iOS LÖVE runtime
- patched Android LOVE runtime

Desktop-only users do not get BLE support from the Lua code alone.

## Lua Requirement

The reusable integration point should become:

```lua
local ble_net = require("ble_net")
```

That package should expose a small stable surface, for example:

```lua
ble_net.host(opts)
ble_net.scan()
ble_net.join(room_id)
ble_net.leave()
ble_net.send(peer_id, msg_type, payload)
ble_net.update()
ble_net.poll()
```

The exact API can evolve, but the package should stay:
- UI-agnostic
- demo-independent
- thin over `love.ble`

## Example Consumer

`demo-chat` should remain an example consumer of the Lua package.

It should demonstrate:
- host/join flow
- room discovery
- message send/receive
- migration handling
- diagnostics UI

But downstream users should not be forced to reuse that UI structure.

## Recommended Downstream Flow

1. Build or obtain a patched native runtime.
2. Vendor `lua/ble_net` into the target LOVE project.
3. Start from a minimal example, not from the full debug demo.
4. Replace example UI while keeping the package API.

## Packaging Recommendation

When this repo is refactored:

- `lua/ble_net` should be copyable as a plain Lua directory
- examples should run without repo-relative hacks
- scripts should package examples, not define the integration surface

## What Should Not Be Required

Downstream users should not need to:
- edit native BLE code just to use the Lua layer
- import the `demo-chat` UI
- understand internal diagnostics code to host and join rooms
