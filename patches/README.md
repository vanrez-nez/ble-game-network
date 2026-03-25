## BLE Native Patches

These patches keep vendor repositories external while storing our BLE bridge work in this repo.

### Development Flow

- Develop natively in:
  - `love/`
  - `love-android/`
- For Android builds, sync the vendored engine copy when needed:

```bash
./scripts/sync-android-vendor-love.sh
```

- Only regenerate patches when you want to freeze/export the current native state:

```bash
./scripts/export-vendor-patches.sh
```

### Patch Targets

- `patches/love/0001-add-ble-module.patch`
  - applies to the standalone `love/` checkout
- `patches/love-android/0001-add-android-ble-bridge.patch`
  - applies to the `love-android/` wrapper repo
- `patches/love-android-vendor-love/0001-add-ble-module.patch`
  - applies to `love-android/app/src/main/cpp/love/`

### Base Commits

- `love`: `ab8dfaa1da571d6ebb09ff1fccb91e5039fce7a0`
- `love-android`: `007d258cb477e51a08229f3d35179966da6e22d3`
- `love-android/app/src/main/cpp/love`: `5670df13b6980afd025cd7e7d442a24499bf86a7`

Apply each patch on top of the matching base commit.

### Apply All Patches

From the repo root:

```bash
./scripts/apply-vendor-patches.sh
```

The script:

- verifies each vendor checkout exists
- verifies each checkout is at the expected base commit
- refuses to run if any vendor checkout has uncommitted changes
- applies all three BLE patches in the correct order

### Manual Apply

#### Standalone LOVE

```bash
git -C love checkout ab8dfaa1da571d6ebb09ff1fccb91e5039fce7a0
git -C love apply patches/love/0001-add-ble-module.patch
```

#### Android Wrapper

```bash
git -C love-android checkout 007d258cb477e51a08229f3d35179966da6e22d3
git -C love-android apply patches/love-android/0001-add-android-ble-bridge.patch
```

#### Android Vendored LOVE

```bash
git -C love-android/app/src/main/cpp/love checkout 5670df13b6980afd025cd7e7d442a24499bf86a7
git -C love-android/app/src/main/cpp/love apply ../../../../../patches/love-android-vendor-love/0001-add-ble-module.patch
```

### Notes

- These are plain diff patches. Use `git apply`, not `git am`.
- The LOVE patches intentionally exclude unrelated local deployment edits:
  - fused game embedding
  - bundle identifier overrides
  - development team / signing overrides
- The vendor repos remain external resources. This repo owns the patch files, Lua layer, demo, scripts, and docs.
