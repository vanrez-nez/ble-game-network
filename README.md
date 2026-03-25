# BLE Game Network

Experimental BLE networking support for LÖVE, with native engine changes for iOS and Android and a Lua demo app.

## Current Repo Shape

- [love](/Users/vanrez/Documents/game-dev/ble-game-network/love)
  - upstream LÖVE engine repo with BLE bridge changes
- [love-android](/Users/vanrez/Documents/game-dev/ble-game-network/love-android)
  - upstream LOVE Android repo with BLE bridge changes
- [demo-chat](/Users/vanrez/Documents/game-dev/ble-game-network/demo-chat)
  - example `.love` project used to exercise the BLE API
- [deploy-demo-ios.sh](/Users/vanrez/Documents/game-dev/ble-game-network/deploy-demo-ios.sh)
  - packages and deploys the demo to iOS
- [deploy-demo-android.sh](/Users/vanrez/Documents/game-dev/ble-game-network/deploy-demo-android.sh)
  - packages and deploys the demo to Android

## Intended Direction

The repo should evolve toward three layers:

1. Native BLE engine patches
   - minimal BLE-only diffs on top of upstream `love` and `love-android`
2. Reusable Lua integration package
   - future home: [lua/ble_net](/Users/vanrez/Documents/game-dev/ble-game-network/lua/ble_net)
3. Example projects
   - keep [demo-chat](/Users/vanrez/Documents/game-dev/ble-game-network/demo-chat) as a consumer/example

## Integration Path

The intended integration path for downstream users is:

1. Use a patched native LÖVE build that includes the BLE bridge.
2. Copy or vendor the reusable Lua package from `lua/ble_net`.
3. Use an example project as the starting point, not the demo UI itself.

Detailed docs:

- [Target Repo Structure](/Users/vanrez/Documents/game-dev/ble-game-network/docs/repo-structure.md)
- [Integration Guide](/Users/vanrez/Documents/game-dev/ble-game-network/docs/integration.md)
- [Migration Plan](/Users/vanrez/Documents/game-dev/ble-game-network/docs/migration-plan.md)

## Upstream Tracking

Both native codebases currently track upstream directly:

- `love` origin: `https://github.com/love2d/love.git`
- `love-android` origin: `https://github.com/love2d/love-android.git`

The goal is to keep BLE-only native diffs isolated so later upstream pulls remain manageable.
