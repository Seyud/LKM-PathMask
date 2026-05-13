#!/system/bin/sh

MODDIR=${0%/*}
LOG_TAG=nohello
KO_PATH="$MODDIR/nohello.ko"
CONFIG_PATH="$MODDIR/target_path.conf"
HIDE_DIRENTS_CONFIG="$MODDIR/hide_dirents.conf"
TARGET_PATH="/data/local/tmp/nohello"
HIDE_DIRENTS=1

log_i() {
	log -p i -t "$LOG_TAG" "$*"
}

log_e() {
	log -p e -t "$LOG_TAG" "$*"
}

if [ -f "$CONFIG_PATH" ]; then
	TARGET_PATH="$(head -n 1 "$CONFIG_PATH" | tr -d '\r')"
fi

if [ -f "$HIDE_DIRENTS_CONFIG" ]; then
	HIDE_DIRENTS="$(head -n 1 "$HIDE_DIRENTS_CONFIG" | tr -d '\r')"
fi

case "$HIDE_DIRENTS" in
	0|false|False|no|No)
		HIDE_DIRENTS=0
		;;
	*)
		HIDE_DIRENTS=1
		;;
esac

if [ -z "$TARGET_PATH" ]; then
	log_e "empty target path"
	exit 1
fi

if [ ! -f "$KO_PATH" ]; then
	log_e "missing module: $KO_PATH"
	exit 1
fi

sleep 10

if grep -q '^nohello ' /proc/modules 2>/dev/null; then
	log_i "nohello is already loaded"
	exit 0
fi

if [ ! -e "$TARGET_PATH" ]; then
	log_i "target does not exist, skip loading: $TARGET_PATH"
	exit 0
fi

if insmod "$KO_PATH" target_path="$TARGET_PATH" hide_dirents="$HIDE_DIRENTS"; then
	log_i "loaded $KO_PATH target_path=$TARGET_PATH hide_dirents=$HIDE_DIRENTS"
else
	log_e "failed to load $KO_PATH"
	exit 1
fi
