# Demo Chat

Small LÖVE demo that exercises the implemented `love.ble` API as a chat app.

It requires a build of LÖVE that includes the native BLE module. There is no
mock backend anymore.

## Run

```bash
love demo-chat
```

For Android deployment, use [deploy-demo-android.sh](/Users/vanrez/Documents/game-dev/ble-game-network/deploy-demo-android.sh) from the repo root.

For iOS deployment, use [deploy-demo-ios.sh](/Users/vanrez/Documents/game-dev/ble-game-network/deploy-demo-ios.sh) from the repo root.

## Controls

- click `Host Reliable` or `Host Resilient` to create a room
- click `Scan Rooms` to discover nearby rooms
- click a room row to join it
- type in the input box
- press `Enter` or click `Send`
- press `Escape` to leave the session

## Purpose

This demo is the acceptance target for the BLE module:

- room discovery
- host and join lifecycle
- live local peer / host state via `local_id`, `is_host`, and `peers()`
- roster updates
- message send and receive
- graceful migration state UI
- session end and radio error handling
