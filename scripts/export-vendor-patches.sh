#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMPDIR_CLEANUP="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CLEANUP"' EXIT

LOVE_DIR="$ROOT_DIR/love"
LOVE_ANDROID_DIR="$ROOT_DIR/love-android"
LOVE_ANDROID_VENDOR_DIR="$LOVE_ANDROID_DIR/app/src/main/cpp/love"

mkdir -p "$ROOT_DIR/patches/love" "$ROOT_DIR/patches/love-android" "$ROOT_DIR/patches/love-android-vendor-love"

git -C "$LOVE_DIR" add -N src/modules/ble >/dev/null 2>&1 || true
git -C "$LOVE_ANDROID_VENDOR_DIR" add -N src/modules/ble >/dev/null 2>&1 || true

git -C "$LOVE_DIR" diff -- \
	CMakeLists.txt \
	platform/xcode/ios/love-ios.plist \
	platform/xcode/liblove.xcodeproj/project.pbxproj \
	src/common/Module.h \
	src/common/android.cpp \
	src/common/android.h \
	src/common/config.h \
	src/modules/love/love.cpp \
	src/modules/ble \
	> "$ROOT_DIR/patches/love/0001-add-ble-module.patch"

git -C "$LOVE_DIR" diff -- platform/xcode/love.xcodeproj/project.pbxproj > "$TMPDIR_CLEANUP/love-ios-project.diff"
# Include only the first 3 BLE-related hunks; later hunks are unrelated build settings.
awk 'BEGIN{n=0} /^@@ /{n++; if(n>3) exit} {print}' "$TMPDIR_CLEANUP/love-ios-project.diff" >> "$ROOT_DIR/patches/love/0001-add-ble-module.patch"

git -C "$LOVE_ANDROID_DIR" diff -- \
	app/src/main/AndroidManifest.xml \
	app/src/main/java/org/love2d/android/GameActivity.java \
	app/src/main/java/org/love2d/android/ble \
	> "$ROOT_DIR/patches/love-android/0001-add-android-ble-bridge.patch"

git -C "$LOVE_ANDROID_VENDOR_DIR" diff -- \
	CMakeLists.txt \
	platform/xcode/ios/love-ios.plist \
	platform/xcode/liblove.xcodeproj/project.pbxproj \
	src/common/Module.h \
	src/common/android.cpp \
	src/common/android.h \
	src/common/config.h \
	src/modules/love/love.cpp \
	src/modules/ble \
	> "$ROOT_DIR/patches/love-android-vendor-love/0001-add-ble-module.patch"

git -C "$LOVE_ANDROID_VENDOR_DIR" diff -- platform/xcode/love.xcodeproj/project.pbxproj > "$TMPDIR_CLEANUP/love-android-vendor-ios-project.diff"
# Include only the first 3 BLE-related hunks; later hunks are unrelated build settings.
awk 'BEGIN{n=0} /^@@ /{n++; if(n>3) exit} {print}' "$TMPDIR_CLEANUP/love-android-vendor-ios-project.diff" >> "$ROOT_DIR/patches/love-android-vendor-love/0001-add-ble-module.patch"

echo "exported vendor BLE patches"

