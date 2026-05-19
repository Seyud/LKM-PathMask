#!/system/bin/sh
# Collect PathMask crash evidence immediately after a reboot caused by hot reload.

set -u

STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
OUT_DIR="${1:-/sdcard/PathMask-diag-after-reboot-$STAMP}"
CONFIG_DIR="/data/adb/pathmask"
MODULE_DIR="/data/adb/modules/pathmask"

mkdir -p "$OUT_DIR/pstore" 2>/dev/null || {
	echo "Cannot create output directory: $OUT_DIR" >&2
	exit 1
}

write_shell() {
	FILE="$1"
	shift
	{
		echo "$ $*"
		sh -c "$*"
	} > "$OUT_DIR/$FILE" 2>&1
}

write_shell "00-basic.txt" "
date
id
uname -a
getprop ro.build.version.release
getprop ro.product.manufacturer
getprop ro.product.device
getprop ro.build.fingerprint
getprop ro.boot.verifiedbootstate
getprop ro.boot.vbmeta.device_state
"

write_shell "01-module-state.txt" "
echo '--- modules ---'
grep -E '^(pathmask|nohello|kernelsu) ' /proc/modules 2>/dev/null || true
echo '--- module files ---'
ls -l '$MODULE_DIR' 2>/dev/null || true
echo '--- module.prop ---'
cat '$MODULE_DIR/module.prop' 2>/dev/null || true
echo '--- load failure guard ---'
cat '$CONFIG_DIR/load_fail_count' 2>/dev/null || echo 0
cat '$CONFIG_DIR/load_fail_reason' 2>/dev/null || true
"

write_shell "02-config.txt" "
for f in \
'$CONFIG_DIR/target_path.conf' \
'$CONFIG_DIR/scope_mode.conf' \
'$CONFIG_DIR/hide_dirents.conf' \
'$CONFIG_DIR/deny_packages.conf' \
'$CONFIG_DIR/deny_uids.conf' \
'$CONFIG_DIR/target_wait_seconds.conf' \
'$CONFIG_DIR/package_wait_seconds.conf'; do
	echo \"### \$f\"
	cat \"\$f\" 2>/dev/null || echo '(missing)'
	echo
done
"

write_shell "03-logcat-pathmask.txt" "logcat -d -s pathmask kernelsu 2>/dev/null || true"
write_shell "04-dmesg-filtered.txt" "dmesg 2>/dev/null | grep -Ei 'pathmask|kernelsu|unknown symbol|invalid module|module_layout|kprobe|kretprobe|panic|oops|bug|pc :|lr :' || true"
write_shell "05-pstore-list.txt" "ls -l /sys/fs/pstore 2>/dev/null || true"

PSTORE_FILTER="$OUT_DIR/06-pstore-filtered.txt"
: > "$PSTORE_FILTER"
FOUND_PSTORE=0
for f in /sys/fs/pstore/*; do
	[ -f "$f" ] || continue
	FOUND_PSTORE=1
	BASE="$(basename "$f")"
	cat "$f" > "$OUT_DIR/pstore/$BASE.txt" 2>/dev/null || true
	{
		echo "### $f"
		grep -Ei 'pathmask|kernelsu|panic|Oops|BUG|Unable|kprobe|kretprobe|kern_path|path_put|security_inode|getdents|pc :|lr :' "$f" 2>/dev/null || true
		echo
	} >> "$PSTORE_FILTER"
done

if [ "$FOUND_PSTORE" -eq 0 ]; then
	echo "(no pstore files found)" >> "$PSTORE_FILTER"
fi

cat > "$OUT_DIR/README.txt" <<'EOF'
This package was collected after a reboot caused by PathMask WebUI hot reload.

Please send this archive together with the "before" archive.
The most important files are:
- 06-pstore-filtered.txt
- pstore/*
- 04-dmesg-filtered.txt
- 01-module-state.txt
EOF

if command -v tar >/dev/null 2>&1; then
	ARCHIVE="$OUT_DIR.tgz"
	(
		cd "$(dirname "$OUT_DIR")" &&
		tar -czf "$ARCHIVE" "$(basename "$OUT_DIR")"
	) 2>/dev/null && echo "Archive: $ARCHIVE"
fi

echo "Report directory: $OUT_DIR"
