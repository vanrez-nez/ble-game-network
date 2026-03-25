# Target Repo Structure

This is the target structure for making the BLE bridge reusable outside the demo app.

## Goal

Separate:

1. upstream-native engine dependencies
2. BLE-only native patches
3. reusable Lua integration code
4. example/demo projects

## Target Layout

```text
ble-game-network/
  README.md
  docs/
    integration.md
    migration-plan.md
    repo-structure.md
  scripts/
    deploy-demo-ios.sh
    deploy-demo-android.sh
  patches/
    love/
    love-android/
  vendor/
    love/
    love-android/
  lua/
    ble_net/
      init.lua
      client.lua
      host.lua
      protocol.lua
      diagnostics.lua
  demo-chat/
    main.lua
    conf.lua
    README.md
  examples/
    minimal-chat/
      main.lua
      conf.lua
```

## Responsibilities

### `vendor/love`

Upstream LÖVE engine source with only BLE-related engine changes applied on top.

Should contain:
- shared BLE module API
- iOS BLE implementation
- bridge code required by the engine

Should not contain:
- demo-specific UI logic
- non-BLE runtime behavior changes

### `vendor/love-android`

Upstream LOVE Android runtime/app source with only BLE-related Android changes.

Should contain:
- Java BLE manager
- Android manifest/runtime requirements for BLE
- Android-side glue required by the bridge

Should not contain:
- demo-specific behavior
- non-BLE app customization

### `patches/`

Exported BLE-only diffs against the tracked upstream engine repos.

Purpose:
- reviewable patch history
- reapplication against fresh upstream checkouts
- documented native delta for downstream maintainers

### `lua/ble_net`

Reusable Lua package intended to be copied or vendored into downstream LOVE projects.

This should become the product-facing Lua layer.

It should contain:
- room/session lifecycle helpers
- event translation
- protocol helpers
- optional diagnostics helpers

It should not contain:
- demo-specific layout/UI code

### `demo-chat`

Example consumer of the BLE Lua package.

Purpose:
- acceptance target
- debugging app
- demonstration of host/join/message flow

### `examples/minimal-chat`

Minimal reference project with almost no diagnostics or custom UI.

Purpose:
- smallest integration example for downstream adopters

## Why This Structure

It reduces pain in two places:

1. upstream maintenance
   - native changes stay isolated and easier to rebase
2. downstream adoption
   - users integrate a Lua package plus patched runtime, not an entire demo app
