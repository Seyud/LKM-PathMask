#!/usr/bin/env sh
set -eu

KO_PATH="${1:-kernel/nohello.ko}"
OUTPUT="${2:-out/nohello-ksu.zip}"
TARGET_PATHS="${TARGET_PATHS:-${TARGET_PATH:-/data/incremental/MT_data_app_vmdl192}}"
HIDE_DIRENTS="${HIDE_DIRENTS:-1}"
HIDE_MOUNTS="${HIDE_MOUNTS:-1}"
SCOPE_MODE="${SCOPE_MODE:-deny}"
DENY_PACKAGES="${DENY_PACKAGES:-me.garfieldhan.holmes}"
DENY_UIDS="${DENY_UIDS:-}"
TARGET_WAIT_SECONDS="${TARGET_WAIT_SECONDS:-90}"
PACKAGE_WAIT_SECONDS="${PACKAGE_WAIT_SECONDS:-90}"

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
printf '%s' "$TARGET_PATHS" | tr ',' '\n' > "$STAGE_DIR/target_path.conf"
printf '%s' "$HIDE_DIRENTS" > "$STAGE_DIR/hide_dirents.conf"
printf '%s' "$HIDE_MOUNTS" > "$STAGE_DIR/hide_mounts.conf"
printf '%s' "$SCOPE_MODE" > "$STAGE_DIR/scope_mode.conf"
printf '%s' "$DENY_PACKAGES" | tr ',' '\n' > "$STAGE_DIR/deny_packages.conf"
printf '%s' "$DENY_UIDS" | tr ',' '\n' > "$STAGE_DIR/deny_uids.conf"
printf '%s' "$TARGET_WAIT_SECONDS" > "$STAGE_DIR/target_wait_seconds.conf"
printf '%s' "$PACKAGE_WAIT_SECONDS" > "$STAGE_DIR/package_wait_seconds.conf"
chmod 0755 "$STAGE_DIR/service.sh" "$STAGE_DIR/uninstall.sh"

rm -f "$OUTPUT"
(cd "$STAGE_DIR" && zip -q -r "$OUTPUT" .)

echo "Created KernelSU package: $OUTPUT"
echo "Target paths: $TARGET_PATHS"
echo "Hide dirents: $HIDE_DIRENTS"
echo "Hide mounts: $HIDE_MOUNTS"
echo "Scope mode: $SCOPE_MODE"
echo "Deny packages: $DENY_PACKAGES"
echo "Deny UIDs: $DENY_UIDS"
echo "Target wait seconds: $TARGET_WAIT_SECONDS"
echo "Package wait seconds: $PACKAGE_WAIT_SECONDS"
