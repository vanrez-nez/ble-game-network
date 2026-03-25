#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

SRC="$ROOT_DIR/love"
DST="$ROOT_DIR/love-android/app/src/main/cpp/love"

for repo in "$SRC" "$DST"
do
	if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
		echo "error: missing git repo at $repo" >&2
		exit 1
	fi
done

if [ -n "$(git -C "$DST" status --short)" ]; then
	echo "error: love-android vendored love has uncommitted changes" >&2
	exit 1
fi

mkdir -p "$DST/src/modules"

cp "$SRC/CMakeLists.txt" "$DST/CMakeLists.txt"
cp "$SRC/platform/xcode/ios/love-ios.plist" "$DST/platform/xcode/ios/love-ios.plist"
cp "$SRC/platform/xcode/liblove.xcodeproj/project.pbxproj" "$DST/platform/xcode/liblove.xcodeproj/project.pbxproj"
cp "$SRC/platform/xcode/love.xcodeproj/project.pbxproj" "$DST/platform/xcode/love.xcodeproj/project.pbxproj"
cp "$SRC/src/common/Module.h" "$DST/src/common/Module.h"
cp "$SRC/src/common/android.cpp" "$DST/src/common/android.cpp"
cp "$SRC/src/common/android.h" "$DST/src/common/android.h"
cp "$SRC/src/common/config.h" "$DST/src/common/config.h"
cp "$SRC/src/modules/love/love.cpp" "$DST/src/modules/love/love.cpp"
rm -rf "$DST/src/modules/ble"
cp -R "$SRC/src/modules/ble" "$DST/src/modules/ble"

echo "synced BLE engine files into love-android vendored love"
