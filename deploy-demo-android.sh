#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$ROOT_DIR/demo-chat"
LUA_DIR="$ROOT_DIR/lua"
LOVE_DIR="$ROOT_DIR/love"
ANDROID_DIR="$ROOT_DIR/love-android"
ANDROID_LOVE_DIR="$ANDROID_DIR/app/src/main/cpp/love"
EMBED_ASSETS_DIR="$ANDROID_DIR/app/src/embed/assets"
GRADLE_PROPERTIES="$ANDROID_DIR/gradle.properties"

BUILD_TYPE="Debug"
RECORDING="NoRecord"
INSTALL_APK=1
LAUNCH_APP=1
DEVICE_SERIAL=""
SHOW_LOGCAT=0
LOGCAT_LIVE=0
CLEAN_NATIVE=1

usage() {
  cat <<'EOF'
Usage: ./deploy-demo-android.sh [options]

Builds the embedded Android app with demo-chat assets, installs it on a
connected device, and launches it.

Options:
  --release       Build the release APK instead of debug
  --record        Build the microphone-enabled variant
  --build-only    Build only, skip adb install and launch
  --no-launch     Install but do not launch the app
  --no-clean      Reuse existing Gradle/CMake native outputs
  --logcat        Print filtered app logcat output and exit
  --logcat-live   Stream filtered app logcat output until interrupted
  --serial SERIAL Use a specific adb device serial
  --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      BUILD_TYPE="Release"
      ;;
    --record)
      RECORDING="Record"
      ;;
    --build-only)
      INSTALL_APK=0
      LAUNCH_APP=0
      ;;
    --no-launch)
      LAUNCH_APP=0
      ;;
    --no-clean)
      CLEAN_NATIVE=0
      ;;
    --logcat)
      SHOW_LOGCAT=1
      INSTALL_APK=0
      LAUNCH_APP=0
      ;;
    --logcat-live)
      SHOW_LOGCAT=1
      LOGCAT_LIVE=1
      INSTALL_APK=0
      LAUNCH_APP=0
      ;;
    --serial)
      shift
      if [[ $# -eq 0 ]]; then
        echo "error: --serial requires a device id" >&2
        exit 1
      fi
      DEVICE_SERIAL="$1"
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

ADB_CMD=(adb)
if [[ -n "$DEVICE_SERIAL" ]]; then
  ADB_CMD+=( -s "$DEVICE_SERIAL" )
fi

LOGCAT_PATTERN='org.love2d.android|GameActivity|AndroidRuntime|FATAL|libc|DEBUG|SDL|love|Lua'

print_filtered_logcat() {
  if ! command -v adb >/dev/null 2>&1; then
    echo "error: adb was not found in PATH" >&2
    exit 1
  fi

  if [[ "$LOGCAT_LIVE" -eq 1 ]]; then
    "${ADB_CMD[@]}" logcat | grep -E "$LOGCAT_PATTERN"
  else
    "${ADB_CMD[@]}" logcat -b crash -d
    "${ADB_CMD[@]}" logcat -d | grep -E "$LOGCAT_PATTERN" || true
  fi
}

if [[ "$SHOW_LOGCAT" -eq 1 ]]; then
  print_filtered_logcat
  exit 0
fi

if [[ ! -d "$DEMO_DIR" ]]; then
  echo "error: demo directory not found: $DEMO_DIR" >&2
  exit 1
fi

if [[ ! -d "$LOVE_DIR" ]]; then
  echo "error: engine source directory not found: $LOVE_DIR" >&2
  exit 1
fi

if [[ ! -f "$ANDROID_DIR/gradlew" ]]; then
  echo "error: love-android gradle wrapper not found: $ANDROID_DIR/gradlew" >&2
  exit 1
fi

if [[ ! -d "$ANDROID_LOVE_DIR" ]]; then
  echo "error: android engine directory not found: $ANDROID_LOVE_DIR" >&2
  exit 1
fi

mkdir -p "$EMBED_ASSETS_DIR"

echo "Syncing engine sources into love-android..."
if command -v rsync >/dev/null 2>&1; then
  rsync -r --delete --exclude '.git' "$LOVE_DIR"/ "$ANDROID_LOVE_DIR"/
else
  echo "error: rsync is required to sync the engine sources for Android builds" >&2
  exit 1
fi

echo "Syncing demo-chat into embed assets..."
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "$DEMO_DIR"/ "$EMBED_ASSETS_DIR"/
  rsync -a --delete "$LUA_DIR/ble_net"/ "$EMBED_ASSETS_DIR/ble_net"/
else
  find "$EMBED_ASSETS_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -R "$DEMO_DIR"/. "$EMBED_ASSETS_DIR"/
  cp -R "$LUA_DIR/ble_net" "$EMBED_ASSETS_DIR"/
fi

if [[ "$CLEAN_NATIVE" -eq 1 ]]; then
  echo "Clearing stale native build outputs..."
  rm -rf "$ANDROID_DIR/app/.cxx"
fi

VARIANT="Embed${RECORDING}${BUILD_TYPE}"
ASSEMBLE_TASK=":app:assemble${VARIANT}"
APK_DIR="$ANDROID_DIR/app/build/outputs/apk/embed${RECORDING}/$(printf '%s' "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"

echo "Building $VARIANT..."
(
  cd "$ANDROID_DIR"
  ./gradlew "$ASSEMBLE_TASK"
)

APK_PATH=""
if [[ -d "$APK_DIR" ]]; then
  APK_PATH="$(find "$APK_DIR" -type f -name '*.apk' | sort | tail -n 1)"
fi

if [[ -z "$APK_PATH" ]]; then
  APK_PATH="$(find "$ANDROID_DIR/app/build/outputs/apk" -type f -name '*.apk' | sort | tail -n 1)"
fi

if [[ -z "$APK_PATH" ]]; then
  echo "error: could not find built APK under $ANDROID_DIR/app/build/outputs/apk" >&2
  exit 1
fi

echo "Built APK:"
echo "  $APK_PATH"

if [[ "$INSTALL_APK" -eq 0 ]]; then
  exit 0
fi

if ! command -v adb >/dev/null 2>&1; then
  echo "error: adb was not found in PATH" >&2
  exit 1
fi

APP_ID="$(awk -F= '/^app.application_id=/{print $2}' "$GRADLE_PROPERTIES" | tail -n 1)"
if [[ -z "$APP_ID" ]]; then
  echo "error: could not determine application id from $GRADLE_PROPERTIES" >&2
  exit 1
fi

echo "Installing on device..."
"${ADB_CMD[@]}" install -r "$APK_PATH"

if [[ "$LAUNCH_APP" -eq 1 ]]; then
  echo "Launching $APP_ID..."
  "${ADB_CMD[@]}" shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 >/dev/null
fi
