# Migration Plan

This plan describes how to move from the current blended repo into a cleaner reusable structure.

## Current State

Today the repo contains:
- two upstream native repos with BLE changes in place
- one demo app that also acts as the test harness
- deployment scripts tied directly to the demo

This works for development, but it is not the best downstream integration surface.

## Migration Goal

End state:
- native BLE patches remain isolated and upstream-trackable
- reusable Lua logic lives outside the demo
- the demo becomes an example consumer
- a minimal example exists for adoption

## Phase 1: Document the Boundaries

Status: start here

Tasks:
- add a top-level README
- define target repo structure
- define downstream integration path
- define migration steps before moving code

Deliverables:
- [README.md](/Users/vanrez/Documents/game-dev/ble-game-network/README.md)
- [docs/repo-structure.md](/Users/vanrez/Documents/game-dev/ble-game-network/docs/repo-structure.md)
- [docs/integration.md](/Users/vanrez/Documents/game-dev/ble-game-network/docs/integration.md)

## Phase 2: Extract Reusable Lua Logic

Tasks:
- create `lua/ble_net`
- move reusable protocol/session/event logic out of `demo-chat/main.lua`
- leave demo-specific rendering and controls in `demo-chat`

Success condition:
- `demo-chat` works while importing the extracted Lua package

## Phase 3: Add Minimal Example

Tasks:
- create `examples/minimal-chat`
- implement the smallest host/join/send example
- keep diagnostics optional

Success condition:
- a downstream developer can understand integration without reading `demo-chat`

## Phase 4: Normalize Scripts

Tasks:
- keep deploy scripts focused on examples/apps
- avoid using scripts as the integration API
- ensure packaging paths are repo-local and example-specific

Success condition:
- scripts deploy examples cleanly without coupling downstream users to repo internals

## Phase 5: Native Upstream Tracking

Tasks:
- keep `love` and `love-android` as clearly tracked upstream dependencies
- maintain BLE-only branches on top of upstream
- export patch files under `patches/`

Success condition:
- upstream sync and patch review become predictable

## Phase 6: Compatibility Documentation

Tasks:
- record exact upstream commits or tags for both native repos
- record which Lua package version matches which native revisions

Success condition:
- downstream users know which native build and Lua package belong together

## Practical Notes

### Native Changes

Only BLE-related native changes should live in the LOVE codebases.

### Project Configuration

Project configuration changes are acceptable when LOVE does not provide a direct interface.

### Demo

The demo remains useful, but it should not define the public integration boundary.
