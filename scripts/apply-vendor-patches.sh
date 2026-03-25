#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

. "$ROOT_DIR/scripts/vendor-lock.sh"

LOVE_DIR="$ROOT_DIR/love"
LOVE_ANDROID_DIR="$ROOT_DIR/love-android"
LOVE_ANDROID_VENDOR_DIR="$LOVE_ANDROID_DIR/app/src/main/cpp/love"

LOVE_PATCH="$ROOT_DIR/$LOVE_PATCH_PATH"
LOVE_ANDROID_PATCH="$ROOT_DIR/$LOVE_ANDROID_PATCH_PATH"
LOVE_ANDROID_VENDOR_PATCH="$ROOT_DIR/$LOVE_ANDROID_VENDOR_PATCH_PATH"

require_repo() {
	repo_path="$1"
	name="$2"

	if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		echo "error: missing git repo for $name at $repo_path" >&2
		exit 1
	fi
}

require_base_commit() {
	repo_path="$1"
	name="$2"
	expected="$3"

	actual=$(git -C "$repo_path" rev-parse HEAD)
	if [ "$actual" != "$expected" ]; then
		echo "error: $name is at $actual but expected $expected" >&2
		exit 1
	fi
}

apply_patch() {
	repo_path="$1"
	patch_path="$2"
	name="$3"

	if git -C "$repo_path" apply --reverse --check "$patch_path" >/dev/null 2>&1; then
		echo "already applied: $name"
		return 0
	fi

	if ! git -C "$repo_path" apply --check "$patch_path"; then
		echo "error: patch does not apply cleanly for $name" >&2
		exit 1
	fi

	git -C "$repo_path" apply "$patch_path"
	echo "applied: $name"
}

require_repo "$LOVE_DIR" "love"
require_repo "$LOVE_ANDROID_DIR" "love-android"
require_repo "$LOVE_ANDROID_VENDOR_DIR" "love-android vendored love"

require_base_commit "$LOVE_DIR" "love" "$LOVE_BASE_COMMIT"
require_base_commit "$LOVE_ANDROID_DIR" "love-android" "$LOVE_ANDROID_BASE_COMMIT"
require_base_commit "$LOVE_ANDROID_VENDOR_DIR" "love-android vendored love" "$LOVE_ANDROID_VENDOR_BASE_COMMIT"

apply_patch "$LOVE_DIR" "$LOVE_PATCH" "love BLE patch"
apply_patch "$LOVE_ANDROID_VENDOR_DIR" "$LOVE_ANDROID_VENDOR_PATCH" "love-android vendored love BLE patch"
apply_patch "$LOVE_ANDROID_DIR" "$LOVE_ANDROID_PATCH" "love-android wrapper BLE patch"
