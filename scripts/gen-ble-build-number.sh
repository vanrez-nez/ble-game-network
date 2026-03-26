#!/bin/sh
set -eu

ROOT_DIR="${1:?usage: gen-ble-build-number.sh <root-repo-dir> <output-dir> [output-dir...]}"
shift

TREE_HASH=$(git -C "$ROOT_DIR" write-tree 2>/dev/null || echo "unknown")
SHORT_HASH=$(echo "$TREE_HASH" | cut -c1-7)

for OUT_DIR in "$@"; do
  cat > "$OUT_DIR/src/modules/ble/BleVersion.gen.h" <<EOF
/* Auto-generated — do not edit */
#define BLE_BUILD_ID "$SHORT_HASH"
EOF
done

echo "ble build id: $SHORT_HASH"
