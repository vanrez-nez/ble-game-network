#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUA_DIR="$ROOT_DIR/lua"
LOVE_DIR="$ROOT_DIR/love"
ANDROID_DIR="$ROOT_DIR/love-android"
ANDROID_LOVE_DIR="$ANDROID_DIR/app/src/main/cpp/love"
GRADLE_PROPERTIES="$ANDROID_DIR/gradle.properties"
ARCHIVE_DIR="$ROOT_DIR/.build/android-demo-archives"

BUILD_TYPE="Debug"
RECORDING="NoRecord"
INSTALL_APK=1
LAUNCH_APP=1
DEVICE_SERIAL=""
SHOW_LOGCAT=0
LOGCAT_LIVE=0
CLEAN_NATIVE=1

DEMO_DIRS=()
DEMO_ARCHIVES=()

get_demo_build_id() {
  git -C "$ROOT_DIR" describe --always --dirty --broken 2>/dev/null || echo "unknown"
}

usage() {
  cat <<'EOF'
Usage: ./deploy-demo-android.sh [options]

Builds the Android app, packages every demo-* project as its own .love file,
installs the app, copies the demos into the app games folder, and lets the
LOVE launcher choose between them.

Options:
  --release       Build the release APK instead of debug
  --record        Build the microphone-enabled variant
  --build-only    Build only, skip adb install and launch
  --no-launch     Install and copy demos, but do not launch the app
  --no-clean      Reuse existing Gradle/CMake native outputs
  --logcat        Print filtered app logcat output and exit
  --logcat-live   Stream filtered app logcat output until interrupted
  --serial SERIAL Use a specific adb device serial
  --help          Show this help
EOF
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

package_demo_archives() {
  local demo_dir demo_name archive_root archive_path build_id

  build_id="$(get_demo_build_id)"

  rm -rf "$ARCHIVE_DIR"
  mkdir -p "$ARCHIVE_DIR"
  DEMO_ARCHIVES=()

  for demo_dir in "${DEMO_DIRS[@]}"; do
    demo_name="$(basename "$demo_dir")"
    archive_root="$ARCHIVE_DIR/$demo_name-root"
    archive_path="$ARCHIVE_DIR/$demo_name.love"

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

    printf '%s\n' "$build_id" > "$archive_root/ble-build-id.txt"

    (
      cd "$archive_root"
      zip -qr "$archive_path" .
    )

    DEMO_ARCHIVES+=("$archive_path")
  done
}

require_ble_modules() {
  if [[ -f "$LOVE_DIR/src/modules/ble/wrap_Ble.cpp" && -f "$ANDROID_DIR/app/src/main/java/org/love2d/android/ble/BleManager.java" && -f "$ANDROID_LOVE_DIR/src/modules/ble/wrap_Ble.cpp" ]]; then
    return 0
  fi

  echo "error: BLE modules are not present in the current vendor checkouts" >&2
  echo "apply the vendor patches explicitly or keep developing in patched vendor checkouts before deploying" >&2
  exit 1
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

select_device() {
  if ! command -v adb >/dev/null 2>&1; then
    echo "error: adb was not found in PATH" >&2
    exit 1
  fi

  local devices=()
  local labels=()
  local line id state model

  while IFS= read -r line; do
    id="${line%%[[:space:]]*}"
    [[ -z "$id" ]] && continue
    state="$(echo "$line" | awk '{print $2}')"
    [[ "$state" != "device" ]] && continue
    model="$(echo "$line" | grep -o 'model:[^ ]*' | cut -d: -f2)"
    devices+=("$id")
    labels+=("${model:-unknown}  ($id)")
  done < <(adb devices -l 2>/dev/null | tail -n +2)

  if [[ "${#devices[@]}" -eq 0 ]]; then
    echo "error: no adb devices connected" >&2
    exit 1
  fi

  if [[ "${#devices[@]}" -eq 1 ]]; then
    DEVICE_SERIAL="${devices[0]}"
    echo "Using device: ${labels[0]}"
    return
  fi

  echo "Multiple devices found:"
  for i in "${!labels[@]}"; do
    echo "  $((i + 1))) ${labels[$i]}"
  done

  local choice
  while true; do
    printf "Select device [1-%d]: " "${#devices[@]}"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#devices[@]} )); then
      DEVICE_SERIAL="${devices[$((choice - 1))]}"
      echo "Using device: ${labels[$((choice - 1))]}"
      return
    fi
    echo "Invalid choice."
  done
}

if [[ -z "$DEVICE_SERIAL" && "$INSTALL_APK" -eq 1 ]]; then
  select_device
fi

ADB_CMD=(adb)
if [[ -n "$DEVICE_SERIAL" ]]; then
  ADB_CMD+=(-s "$DEVICE_SERIAL")
fi

LOGCAT_PATTERN='org.love2d.android|GameActivity|MainActivity|AndroidRuntime|FATAL|libc|DEBUG|SDL|love|Lua'

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

discover_demo_dirs
require_ble_modules

if [[ ! -d "$LOVE_DIR" ]]; then
  echo "error: engine source directory not found: $LOVE_DIR" >&2
  exit 1
fi

if [[ ! -f "$ANDROID_DIR/gradlew" ]]; then
  echo "error: love-android gradle wrapper not found: $ANDROID_DIR/gradlew" >&2
  exit 1
fi

if [[ -z "${ANDROID_HOME:-}" ]]; then
  if [[ -d "$HOME/Library/Android/sdk" ]]; then
    export ANDROID_HOME="$HOME/Library/Android/sdk"
  fi
fi

if [[ -z "${JAVA_HOME:-}" ]]; then
  if [[ -d "/opt/homebrew/opt/openjdk@17" ]]; then
    export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
  elif /usr/libexec/java_home -v 17 >/dev/null 2>&1; then
    export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  fi
fi

if [[ ! -d "$ANDROID_LOVE_DIR" ]]; then
  echo "error: android engine directory not found: $ANDROID_LOVE_DIR" >&2
  exit 1
fi

package_demo_archives

if [[ "$CLEAN_NATIVE" -eq 1 ]]; then
  echo "Syncing engine sources into love-android..."
  if command -v rsync >/dev/null 2>&1; then
    rsync -r --delete --exclude '.git' --exclude '.DS_Store' --exclude 'build/' --exclude '.cxx' --exclude '*.o' "$LOVE_DIR"/ "$ANDROID_LOVE_DIR"/
  else
    echo "error: rsync is required to sync the engine sources for Android builds" >&2
    exit 1
  fi

  echo "Clearing stale native build outputs..."
  rm -rf "$ANDROID_DIR/app/.cxx"
else
  echo "Reusing cached engine sources and native outputs (--no-clean)"
fi

VARIANT="Normal${RECORDING}${BUILD_TYPE}"
ASSEMBLE_TASK=":app:assemble${VARIANT}"
APK_DIR="$ANDROID_DIR/app/build/outputs/apk/normal${RECORDING}/$(printf '%s' "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"

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
echo "Packaged demos:"
for archive_path in "${DEMO_ARCHIVES[@]}"; do
  echo "  $archive_path"
done

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

DEVICE_GAMES_DIR="/sdcard/Android/data/$APP_ID/files/games"

echo "Copying demos to $DEVICE_GAMES_DIR..."
"${ADB_CMD[@]}" shell rm -rf "$DEVICE_GAMES_DIR"
"${ADB_CMD[@]}" shell mkdir -p "$DEVICE_GAMES_DIR"
for archive_path in "${DEMO_ARCHIVES[@]}"; do
  "${ADB_CMD[@]}" push "$archive_path" "$DEVICE_GAMES_DIR/" >/dev/null
done

if [[ "$LAUNCH_APP" -eq 1 ]]; then
  echo "Launching $APP_ID..."
  "${ADB_CMD[@]}" shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 >/dev/null
fi
