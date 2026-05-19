#!/system/bin/sh
# Collect PathMask state before pressing WebUI "save and hot reload".

set -u

STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
OUT_DIR="${1:-/sdcard/PathMask-diag-before-$STAMP}"
CONFIG_DIR="/data/adb/pathmask"
LEGACY_CONFIG_DIR="/data/adb/nohello"
MODULE_DIR="/data/adb/modules/pathmask"
LEGACY_MODULE_DIR="/data/adb/modules/nohello-demo"

mkdir -p "$OUT_DIR" 2>/dev/null || {
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

dump_file() {
	SRC="$1"
	DST="$2"
	{
		echo "### $SRC"
		if [ -f "$SRC" ]; then
			cat "$SRC"
		else
			echo "(missing)"
		fi
		echo
	} >> "$OUT_DIR/$DST" 2>&1
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
echo '--- pathmask module dir ---'
ls -l '$MODULE_DIR' 2>/dev/null || true
echo '--- legacy module dir ---'
ls -l '$LEGACY_MODULE_DIR' 2>/dev/null || true
echo '--- sysfs parameters ---'
for f in /sys/module/pathmask/parameters/*; do [ -f \"\$f\" ] && echo \"\$(basename \"\$f\")=\$(cat \"\$f\" 2>/dev/null)\"; done
"

: > "$OUT_DIR/02-config.txt"
for f in \
	"$CONFIG_DIR/target_path.conf" \
	"$CONFIG_DIR/scope_mode.conf" \
	"$CONFIG_DIR/hide_dirents.conf" \
	"$CONFIG_DIR/deny_packages.conf" \
	"$CONFIG_DIR/deny_uids.conf" \
	"$CONFIG_DIR/target_wait_seconds.conf" \
	"$CONFIG_DIR/package_wait_seconds.conf" \
	"$CONFIG_DIR/load_fail_count" \
	"$CONFIG_DIR/load_fail_reason" \
	"$MODULE_DIR/module.prop" \
	"$LEGACY_CONFIG_DIR/target_path.conf" \
	"$LEGACY_CONFIG_DIR/scope_mode.conf" \
	"$LEGACY_CONFIG_DIR/hide_dirents.conf" \
	"$LEGACY_CONFIG_DIR/deny_packages.conf" \
	"$LEGACY_CONFIG_DIR/deny_uids.conf"; do
	dump_file "$f" "02-config.txt"
done

write_shell "03-target-probe.txt" "
if [ -f '$CONFIG_DIR/target_path.conf' ]; then
	while IFS= read -r p || [ -n \"\$p\" ]; do
		case \"\$p\" in ''|'#'*) continue;; esac
		if [ -e \"\$p\" ]; then
			ls -ld \"\$p\"
		else
			echo \"MISS \$p\"
		fi
	done < '$CONFIG_DIR/target_path.conf'
else
	echo '(missing target_path.conf)'
fi
"

write_shell "04-logcat-pathmask.txt" "logcat -d -s pathmask kernelsu 2>/dev/null || true"
write_shell "05-dmesg-filtered.txt" "dmesg 2>/dev/null | grep -Ei 'pathmask|kernelsu|unknown symbol|invalid module|module_layout|kprobe|kretprobe|panic|oops|bug' || true"
write_shell "06-pstore-list.txt" "ls -l /sys/fs/pstore 2>/dev/null || true"

cat > "$OUT_DIR/README.txt" <<'EOF'
This package was collected before pressing PathMask WebUI "save and hot reload".

Next:
1. Press "保存并热重载 / save and hot reload" once.
2. If the phone reboots, run tools/diagnose_after_reboot.sh immediately after boot.
3. Send both before and after archives.
EOF

if command -v tar >/dev/null 2>&1; then
	ARCHIVE="$OUT_DIR.tgz"
	(
		cd "$(dirname "$OUT_DIR")" &&
		tar -czf "$ARCHIVE" "$(basename "$OUT_DIR")"
	) 2>/dev/null && echo "Archive: $ARCHIVE"
fi

echo "Report directory: $OUT_DIR"
