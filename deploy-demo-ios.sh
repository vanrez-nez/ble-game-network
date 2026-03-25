#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$ROOT_DIR/demo-chat"
LUA_DIR="$ROOT_DIR/lua"
LOVE_DIR="$ROOT_DIR/love"
APPLE_DEPS_DIR="$ROOT_DIR/love-apple-dependencies"
XCODE_PROJECT="$LOVE_DIR/platform/xcode/love.xcodeproj"
IOS_LIBRARIES_LINK="$LOVE_DIR/platform/xcode/ios/libraries"
SHARED_FRAMEWORKS_LINK="$LOVE_DIR/platform/xcode/shared/Frameworks"
DERIVED_DATA_DIR="$ROOT_DIR/.build/ios-demo"
ARCHIVE_DIR="$ROOT_DIR/.build/ios-demo-archive"
ARCHIVE_ROOT_DIR="$ARCHIVE_DIR/root"
LOVE_ARCHIVE="$ARCHIVE_DIR/demo-chat.love"
SCHEME="love-ios"
CONFIGURATION="Debug"
BUNDLE_ID="org.love2d.ble-network"
INSTALL_APP=1
LAUNCH_APP=1
SIMULATOR_ID="booted"
DEVICE_ID=""
CLEAN_BUILD=0

usage() {
  cat <<'EOF'
Usage: ./deploy-demo-ios.sh [options]

Packages demo-chat as a .love archive, embeds it into the iOS app bundle using
the LOVE fused-game packaging path, installs the app, and launches it.

By default this targets the currently booted simulator.

Options:
  --release            Build the Release configuration instead of Debug
  --clean              Remove iOS derived data and packaged archive before build
  --build-only         Build only, skip install/launch
  --no-launch          Install the app, but do not launch it
  --simulator ID       Target a specific simulator UDID or 'booted' (default)
  --device ID          Target a physical device via devicectl instead of simctl
  --bundle-id ID       Override the app bundle identifier
  --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      CONFIGURATION="Release"
      ;;
    --clean)
      CLEAN_BUILD=1
      ;;
    --build-only)
      INSTALL_APP=0
      LAUNCH_APP=0
      ;;
    --no-launch)
      LAUNCH_APP=0
      ;;
    --simulator)
      shift
      if [[ $# -eq 0 ]]; then
        echo "error: --simulator requires a simulator id or 'booted'" >&2
        exit 1
      fi
      SIMULATOR_ID="$1"
      ;;
    --device)
      shift
      if [[ $# -eq 0 ]]; then
        echo "error: --device requires a device identifier" >&2
        exit 1
      fi
      DEVICE_ID="$1"
      ;;
    --bundle-id)
      shift
      if [[ $# -eq 0 ]]; then
        echo "error: --bundle-id requires a value" >&2
        exit 1
      fi
      BUNDLE_ID="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -n "$DEVICE_ID" && "$SIMULATOR_ID" != "booted" ]]; then
  echo "error: use either --device or --simulator, not both" >&2
  exit 1
fi

if [[ ! -d "$DEMO_DIR" ]]; then
  echo "error: demo directory not found: $DEMO_DIR" >&2
  exit 1
fi

if [[ ! -d "$XCODE_PROJECT" ]]; then
  echo "error: Xcode project not found: $XCODE_PROJECT" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild was not found in PATH" >&2
  exit 1
fi

if [[ ! -e "$IOS_LIBRARIES_LINK" || ! -e "$SHARED_FRAMEWORKS_LINK" ]]; then
  if [[ ! -d "$APPLE_DEPS_DIR/iOS/libraries" ]]; then
    echo "error: Apple iOS dependency libraries not found: $APPLE_DEPS_DIR/iOS/libraries" >&2
    exit 1
  fi

  if [[ ! -d "$APPLE_DEPS_DIR/shared/Frameworks" ]]; then
    echo "error: Apple shared frameworks not found: $APPLE_DEPS_DIR/shared/Frameworks" >&2
    exit 1
  fi

  echo "Linking Apple dependency libraries into the Xcode project..."
  mkdir -p "$(dirname "$IOS_LIBRARIES_LINK")" "$(dirname "$SHARED_FRAMEWORKS_LINK")"

  if [[ ! -e "$IOS_LIBRARIES_LINK" ]]; then
    ln -s "$APPLE_DEPS_DIR/iOS/libraries" "$IOS_LIBRARIES_LINK"
  fi

  if [[ ! -e "$SHARED_FRAMEWORKS_LINK" ]]; then
    ln -s "$APPLE_DEPS_DIR/shared/Frameworks" "$SHARED_FRAMEWORKS_LINK"
  fi
fi

if [[ "$CLEAN_BUILD" -eq 1 ]]; then
  rm -rf "$DERIVED_DATA_DIR" "$ARCHIVE_DIR"
fi
mkdir -p "$ARCHIVE_DIR"

echo "Packaging demo-chat as $LOVE_ARCHIVE..."
rm -rf "$ARCHIVE_ROOT_DIR"
mkdir -p "$ARCHIVE_ROOT_DIR/ble_net"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "$DEMO_DIR"/ "$ARCHIVE_ROOT_DIR"/
  rsync -a --delete "$LUA_DIR/ble_net"/ "$ARCHIVE_ROOT_DIR/ble_net"/
else
  cp -R "$DEMO_DIR"/. "$ARCHIVE_ROOT_DIR"/
  cp -R "$LUA_DIR/ble_net"/. "$ARCHIVE_ROOT_DIR/ble_net"/
fi
(
  cd "$ARCHIVE_ROOT_DIR"
  zip -qr "$LOVE_ARCHIVE" .
)

DESTINATION="generic/platform=iOS Simulator"
SDK="iphonesimulator"
PRODUCT_DIR_SUFFIX="iphonesimulator"

if [[ -n "$DEVICE_ID" ]]; then
  DESTINATION="generic/platform=iOS"
  SDK="iphoneos"
  PRODUCT_DIR_SUFFIX="iphoneos"
fi

echo "Building $SCHEME ($CONFIGURATION, $SDK)..."
export LOVE_IOS_FUSED_GAME="$LOVE_ARCHIVE"
xcodebuild \
  -project "$XCODE_PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk "$SDK" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build

APP_PATH="$DERIVED_DATA_DIR/Build/Products/${CONFIGURATION}-${PRODUCT_DIR_SUFFIX}/love.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built app not found: $APP_PATH" >&2
  exit 1
fi

EMBEDDED_ARCHIVE="$APP_PATH/demo-chat.love"
if [[ ! -f "$EMBEDDED_ARCHIVE" ]]; then
  echo "error: fused archive not found in built app: $EMBEDDED_ARCHIVE" >&2
  exit 1
fi

if ! cmp -s "$LOVE_ARCHIVE" "$EMBEDDED_ARCHIVE"; then
  echo "error: built app contains a stale fused archive" >&2
  echo "  source:   $LOVE_ARCHIVE" >&2
  echo "  embedded: $EMBEDDED_ARCHIVE" >&2
  exit 1
fi

echo "Built app:"
echo "  $APP_PATH"
echo "Packaged archive:"
echo "  $LOVE_ARCHIVE"

if [[ "$INSTALL_APP" -eq 0 ]]; then
  exit 0
fi

if [[ -n "$DEVICE_ID" ]]; then
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun was not found in PATH" >&2
    exit 1
  fi

  echo "Installing app on device $DEVICE_ID..."
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

  if [[ "$LAUNCH_APP" -eq 1 ]]; then
    echo "Launching $BUNDLE_ID on device $DEVICE_ID..."
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
  fi

  exit 0
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun was not found in PATH" >&2
  exit 1
fi

echo "Booting simulator $SIMULATOR_ID if needed..."
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true

echo "Installing app on simulator $SIMULATOR_ID..."
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"

if [[ "$LAUNCH_APP" -eq 1 ]]; then
  echo "Launching $BUNDLE_ID on simulator $SIMULATOR_ID..."
  xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID"
fi
