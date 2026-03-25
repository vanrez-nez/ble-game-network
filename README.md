# BLE Game Network

## Project

BLE networking for LÖVE with:

- native BLE bridge code in the external vendor repos:
  - `love`
  - `love-android`
- reusable Lua communication layer in `lua/ble_net`
- example demo projects:
  - `demo-chat`
  - `demo-tictactoe`

This is a generic game communication layer, not a chat-only project. The demos are examples and test apps. The intended integration surface for other games is:

1. patched native LÖVE builds
2. `lua/ble_net`

## How To Use

For development:

1. Apply the native BLE patches once to the vendor repos:

```bash
./scripts/apply-vendor-patches.sh
```

2. Keep developing normally in:
   - `love`
   - `love-android`
   - `lua/ble_net`
   - the demo projects

3. When Android native engine files change in `love`, sync the vendored Android engine copy:

```bash
./scripts/sync-android-vendor-love.sh
```

4. When you want to freeze the current native state back into patch files:

```bash
./scripts/export-vendor-patches.sh
```

For downstream use in another game:

1. start from patched native builds
2. copy or vendor `lua/ble_net`
3. use one of the demo projects as a reference, not as the required UI

## How To Build And Install

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
