#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUA_DIR="$ROOT_DIR/lua"
LOVE_DIR="$ROOT_DIR/love"
APPLE_DEPS_DIR="$ROOT_DIR/love-apple-dependencies"
XCODE_PROJECT="$LOVE_DIR/platform/xcode/love.xcodeproj"
XCODE_PBXPROJ="$XCODE_PROJECT/project.pbxproj"
IOS_LIBRARIES_LINK="$LOVE_DIR/platform/xcode/ios/libraries"
SHARED_FRAMEWORKS_LINK="$LOVE_DIR/platform/xcode/shared/Frameworks"
DERIVED_DATA_DIR="$ROOT_DIR/.build/ios-demo"
ARCHIVE_DIR="$ROOT_DIR/.build/ios-demo-archives"
ARCHIVE_STAGE_DIR="$ARCHIVE_DIR/staging"
SCHEME="love-ios"
CONFIGURATION="Debug"
BUNDLE_ID="org.love2d.ble-network"
DEVELOPMENT_TEAM="${IOS_DEVELOPMENT_TEAM:-}"
INSTALL_APP=1
LAUNCH_APP=1
SIMULATOR_ID="booted"
DEVICE_ID=""
CLEAN_BUILD=0

DEMO_DIRS=()
DEMO_ARCHIVES=()

resolve_project_development_team() {
  if [[ ! -f "$XCODE_PBXPROJ" ]]; then
    return 0
  fi

  awk '
    /DEVELOPMENT_TEAM = / {
      value = $3
      gsub(/[";]/, "", value)
      if (value != "") {
        print value
        exit
      }
    }
  ' "$XCODE_PBXPROJ"
}

discover_demo_dirs() {
  local demo_dir
  for demo_dir in "$ROOT_DIR"/demo-*; do
    if [[ -d "$demo_dir" && -f "$demo_dir/main.lua" ]]; then
      DEMO_DIRS+=("$demo_dir")
    fi
  done

  if [[ "${#DEMO_DIRS[@]}" -eq 0 ]]; then
    echo "error: no demo-* project directories with main.lua were found" >&2
    exit 1
  fi
}

require_ble_module() {
  if [[ -f "$LOVE_DIR/src/modules/ble/wrap_Ble.cpp" ]]; then
    return 0
  fi

  echo "error: BLE module is not present in $LOVE_DIR" >&2
  echo "apply the vendor patches explicitly or keep developing in a patched vendor checkout before deploying" >&2
  exit 1
}

package_demo_archives() {
  local demo_dir demo_name archive_root archive_path

  rm -rf "$ARCHIVE_DIR"
  mkdir -p "$ARCHIVE_STAGE_DIR"
  DEMO_ARCHIVES=()

  for demo_dir in "${DEMO_DIRS[@]}"; do
    demo_name="$(basename "$demo_dir")"
    archive_root="$ARCHIVE_DIR/$demo_name-root"
    archive_path="$ARCHIVE_STAGE_DIR/$demo_name.love"

    echo "Packaging $demo_name as $archive_path..."
    rm -rf "$archive_root"
    mkdir -p "$archive_root"

    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete --exclude '.DS_Store' --exclude '*.swp' --exclude '*.bak' "$demo_dir"/ "$archive_root"/
      rsync -a --exclude '.DS_Store' --exclude '*.swp' --exclude '*.bak' "$LUA_DIR"/ "$archive_root"/
    else
      cp -R "$demo_dir"/. "$archive_root"/
      cp -R "$LUA_DIR"/. "$archive_root"/
    fi

    (
      cd "$archive_root"
      zip -qr "$archive_path" .
    )

    DEMO_ARCHIVES+=("$archive_path")
  done
}

remove_bundled_love_archives() {
  local app_path="$1"

  find "$app_path" -maxdepth 1 -type f -name '*.love' -delete
}

usage() {
  cat <<'EOF'
Usage: ./deploy-demo-ios.sh [options]

Builds the LOVE iOS app, packages every demo-* project as its own .love file,
installs the app, copies the demos into the app Documents directory, and lets
the LOVE selector choose between them.

By default this targets the currently booted simulator.

Options:
  --release            Build the Release configuration instead of Debug
  --clean              Remove iOS derived data and packaged archives before build
  --build-only         Build only, skip install/launch
  --no-launch          Install the app and copy demos, but do not launch it
  --simulator ID       Target a specific simulator UDID or 'booted' (default)
  --device ID          Target a physical device via devicectl instead of simctl
  --bundle-id ID       Override the app bundle identifier
  --team ID            Override the Apple development team identifier
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
    --team)
      shift
      if [[ $# -eq 0 ]]; then
        echo "error: --team requires a value" >&2
        exit 1
      fi
      DEVELOPMENT_TEAM="$1"
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

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  DEVELOPMENT_TEAM="$(resolve_project_development_team)"
fi

if [[ -n "$DEVICE_ID" && -z "$DEVELOPMENT_TEAM" ]]; then
  echo "error: physical device builds require a development team." >&2
  echo "set it in the Xcode project, pass --team <TEAM_ID>, or set IOS_DEVELOPMENT_TEAM" >&2
  exit 1
fi

discover_demo_dirs
require_ble_module

"$ROOT_DIR/scripts/gen-ble-build-number.sh" "$ROOT_DIR" "$LOVE_DIR"

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

package_demo_archives

DESTINATION="generic/platform=iOS Simulator"
SDK="iphonesimulator"
PRODUCT_DIR_SUFFIX="iphonesimulator"

if [[ -n "$DEVICE_ID" ]]; then
  DESTINATION="generic/platform=iOS"
  SDK="iphoneos"
  PRODUCT_DIR_SUFFIX="iphoneos"
fi

echo "Building $SCHEME ($CONFIGURATION, $SDK)..."
xcodebuild_args=(
  -project "$XCODE_PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -sdk "$SDK"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_DIR"
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
)

if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  xcodebuild_args+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

xcodebuild "${xcodebuild_args[@]}" build

APP_PATH="$DERIVED_DATA_DIR/Build/Products/${CONFIGURATION}-${PRODUCT_DIR_SUFFIX}/love.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built app not found: $APP_PATH" >&2
  exit 1
fi

remove_bundled_love_archives "$APP_PATH"

echo "Built app:"
echo "  $APP_PATH"
echo "Packaged demos:"
for archive_path in "${DEMO_ARCHIVES[@]}"; do
  echo "  $archive_path"
done

if [[ "$INSTALL_APP" -eq 0 ]]; then
  exit 0
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun was not found in PATH" >&2
  exit 1
fi

if [[ -n "$DEVICE_ID" ]]; then
  echo "Installing app on device $DEVICE_ID..."
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

  echo "Copying demos to device Documents..."
  xcrun devicectl device copy to \
    --device "$DEVICE_ID" \
    --source "$ARCHIVE_STAGE_DIR" \
    --destination "Documents" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --remove-existing-content true

  if [[ "$LAUNCH_APP" -eq 1 ]]; then
    echo "Launching $BUNDLE_ID on device $DEVICE_ID..."
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
  fi

  exit 0
fi

echo "Booting simulator $SIMULATOR_ID if needed..."
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true

echo "Installing app on simulator $SIMULATOR_ID..."
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"

SIM_DATA_DIR="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" data)"
SIM_DOCUMENTS_DIR="$SIM_DATA_DIR/Documents"

echo "Copying demos to simulator Documents..."
rm -rf "$SIM_DOCUMENTS_DIR"
mkdir -p "$SIM_DOCUMENTS_DIR"
cp "${DEMO_ARCHIVES[@]}" "$SIM_DOCUMENTS_DIR"/

if [[ "$LAUNCH_APP" -eq 1 ]]; then
  echo "Launching $BUNDLE_ID on simulator $SIMULATOR_ID..."
  xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID"
fi
