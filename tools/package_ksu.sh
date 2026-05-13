#!/usr/bin/env sh
set -eu

KO_PATH="${1:-kernel/nohello.ko}"
OUTPUT="${2:-out/nohello-ksu.zip}"
TARGET_PATH="${TARGET_PATH:-/data/local/tmp/nohello}"
HIDE_DIRENTS="${HIDE_DIRENTS:-1}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE_DIR="$REPO_ROOT/ksu-module"
STAGE_DIR="$REPO_ROOT/out/ksu-stage"

case "$KO_PATH" in
/*) ;;
*) KO_PATH="$REPO_ROOT/$KO_PATH" ;;
esac

case "$OUTPUT" in
/*) ;;
*) OUTPUT="$REPO_ROOT/$OUTPUT" ;;
esac

if [ ! -f "$KO_PATH" ]; then
	echo "Missing kernel module: $KO_PATH" >&2
	exit 1
fi

if [ ! -d "$TEMPLATE_DIR" ]; then
	echo "Missing KernelSU template: $TEMPLATE_DIR" >&2
	exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
	echo "Missing dependency: zip" >&2
	exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$(dirname -- "$OUTPUT")"

cp -R "$TEMPLATE_DIR"/. "$STAGE_DIR"/
cp "$KO_PATH" "$STAGE_DIR/nohello.ko"
printf '%s' "$TARGET_PATH" > "$STAGE_DIR/target_path.conf"
printf '%s' "$HIDE_DIRENTS" > "$STAGE_DIR/hide_dirents.conf"
chmod 0755 "$STAGE_DIR/service.sh" "$STAGE_DIR/uninstall.sh"

rm -f "$OUTPUT"
(cd "$STAGE_DIR" && zip -q -r "$OUTPUT" .)

echo "Created KernelSU package: $OUTPUT"
echo "Target path: $TARGET_PATH"
echo "Hide dirents: $HIDE_DIRENTS"
