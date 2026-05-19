#!/system/bin/sh
# Probe whether pathmask.ko can be loaded on this device.
#
# This script is non-destructive:
#   * it does not edit any /data/adb/pathmask config file
#   * it does not touch the "disable" marker
#   * if pathmask is currently loaded, it leaves it alone and skips the test
#   * if pathmask is NOT loaded, it tries one insmod with safe parameters,
#     records the kernel response, then unloads the module again
#
# Usage (module is currently installed under KernelSU):
#   adb push tools/probe_loadable.sh /sdcard/
#   adb shell su -c 'sh /sdcard/probe_loadable.sh'
#
# Usage (module is NOT installed; probe a standalone .ko file):
#   adb push tools/probe_loadable.sh /sdcard/
#   adb push out/android13-5.15_pathmask.ko /sdcard/pathmask.ko
#   adb shell su -c 'KO_PATH=/sdcard/pathmask.ko sh /sdcard/probe_loadable.sh'
#
# Safety:
#   By default the script refuses to insmod a ko whose vermagic prefix does
#   not match `uname -r` and whose __versions section is empty, because that
#   combination has been observed to bypass modversions checks and trip
#   CFI/SCS during kretprobe registration on some OEM kernels (Xiaomi
#   ishtar 5.15.178 + KMI android13-8 confirmed). Set PROBE_FORCE_INSMOD=1
#   only if you know what you are doing and have a working serial console.

set -u

STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
OUT_DIR="${1:-/sdcard/PathMask-probe-$STAMP}"
MODULE_DIR="/data/adb/modules/pathmask"
KO_PATH="${KO_PATH:-$MODULE_DIR/pathmask.ko}"
MODULE_NAME="pathmask"
PROBE_PATH="/dev/null"

# By default we refuse to insmod when the ko is plainly incompatible with
# this kernel. Users can override with PROBE_FORCE_INSMOD=1 if they really
# want to see the kernel response anyway (NOT recommended).
PROBE_FORCE_INSMOD="${PROBE_FORCE_INSMOD:-0}"

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

# 0. Basic device identity
write_shell "00-basic.txt" "
date
id
uname -a
cat /proc/version
getprop ro.build.version.release
getprop ro.product.manufacturer
getprop ro.product.device
getprop ro.build.fingerprint
getprop ro.boot.verifiedbootstate
getprop ro.boot.vbmeta.device_state
"

# 1. Current module / sysfs state
write_shell "01-module-state.txt" "
echo '--- /proc/modules (pathmask|nohello|kernelsu) ---'
grep -E '^(pathmask|nohello|kernelsu) ' /proc/modules 2>/dev/null || true
echo '--- /data/adb/modules/pathmask ---'
ls -l '$MODULE_DIR' 2>/dev/null || true
echo '--- /sys/module/pathmask/parameters ---'
for f in /sys/module/pathmask/parameters/*; do [ -f \"\$f\" ] && echo \"\$(basename \"\$f\")=\$(cat \"\$f\" 2>/dev/null)\"; done
"

# 2. Kernel module-loading policy
write_shell "02-policy.txt" "
echo '--- /sys/module/module/parameters/sig_enforce ---'
cat /sys/module/module/parameters/sig_enforce 2>/dev/null || echo '(not present)'
echo '--- /proc/sys/kernel/modules_disabled ---'
cat /proc/sys/kernel/modules_disabled 2>/dev/null || echo '(not present)'
echo '--- /proc/sys/kernel/kptr_restrict ---'
cat /proc/sys/kernel/kptr_restrict 2>/dev/null || echo '(not present)'
echo '--- /proc/sys/kernel/dmesg_restrict ---'
cat /proc/sys/kernel/dmesg_restrict 2>/dev/null || echo '(not present)'
echo '--- /proc/config.gz (subset) ---'
if [ -f /proc/config.gz ]; then
	zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_(MODVERSIONS|MODULE_SIG|MODULE_FORCE_LOAD|TRIM_UNUSED_KSYMS|KPROBES|KRETPROBES|KALLSYMS|CFI_CLANG|SHADOW_CALL_STACK|HARDENED_USERCOPY|RANDSTRUCT|MODULE_SCMVERSION|UNUSED_SYMBOLS)' || true
else
	echo '(/proc/config.gz not exposed)'
fi
"

# 3. Vermagic / ko metadata
write_shell "03-vermagic.txt" "
echo '--- uname -r ---'
uname -r
echo '--- ko file ---'
ls -l '$KO_PATH' 2>/dev/null || echo '(missing $KO_PATH)'
echo '--- vermagic / srcversion / depends ---'
if [ -f '$KO_PATH' ]; then
	if [ -x /system/bin/modinfo ]; then
		/system/bin/modinfo '$KO_PATH' 2>&1 | head -n 30
	fi
	echo '-- raw strings --'
	grep -aoE 'vermagic=[^[:space:]]+( [^[:space:]]+)*' '$KO_PATH' | head -n 5
	grep -aoE 'srcversion=[^[:space:]]+' '$KO_PATH' | head -n 5
	grep -aoE 'depends=[^[:space:]]*' '$KO_PATH' | head -n 5
fi
"

# 4. Symbols pathmask depends on
write_shell "04-symbols.txt" "
echo '--- /proc/kallsyms snippets ---'
grep -E ' (module_layout|kern_path|path_put|register_kretprobe|unregister_kretprobe|register_kprobe|unregister_kprobe|security_inode_permission|security_inode_getattr|__arm64_sys_getdents64|__se_sys_getdents64|__do_sys_getdents64|strscpy)\$' /proc/kallsyms 2>/dev/null || true
echo
echo '--- counts only (some kernels mask kallsyms addrs) ---'
for sym in module_layout kern_path path_put register_kretprobe unregister_kretprobe security_inode_permission security_inode_getattr __arm64_sys_getdents64 strscpy; do
	c=\"\$(grep -c \" \$sym\$\" /proc/kallsyms 2>/dev/null || echo 0)\"
	echo \"\$sym \$c\"
done
"

# 5. The actual probe: try insmod, record kernel response
{
	echo "$ probe_insmod_pathmask"
	echo

	echo '--- pre-checks ---'
	if [ ! -f "$KO_PATH" ]; then
		echo "FAIL: $KO_PATH does not exist; cannot probe"
		echo "RESULT: skipped (no ko)"
		exit 0
	fi
	if grep -q "^${MODULE_NAME} " /proc/modules 2>/dev/null; then
		echo "SKIP: $MODULE_NAME is already loaded; not interfering"
		echo "RESULT: skipped (already loaded)"
		echo
		echo '--- /proc/modules entry ---'
		grep "^${MODULE_NAME} " /proc/modules
		echo '--- sysfs parameters ---'
		for f in /sys/module/${MODULE_NAME}/parameters/*; do
			[ -f "$f" ] && echo "$(basename "$f")=$(cat "$f" 2>/dev/null)"
		done
		exit 0
	fi
	if grep -q '^nohello ' /proc/modules 2>/dev/null; then
		echo "FAIL: legacy nohello module is loaded; rmmod it first"
		echo "RESULT: skipped (legacy nohello loaded)"
		exit 0
	fi

	# --- ABI sanity gate ---
	# Refuse to insmod when the ko is plainly incompatible with this kernel,
	# because such a load can bypass the vermagic check, succeed the elf load,
	# then trip CFI/SCS during kretprobe registration -- which on some OEM
	# kernels manifests as an instant reboot with no dmesg salvage.
	echo
	echo '--- ABI sanity gate ---'
	KERNEL_REL="$(uname -r 2>/dev/null)"
	echo "kernel uname -r: $KERNEL_REL"

	KO_VERMAGIC=""
	if [ -x /system/bin/modinfo ]; then
		KO_VERMAGIC="$(/system/bin/modinfo "$KO_PATH" 2>/dev/null | awk '/^vermagic:/ {sub(/^vermagic:[[:space:]]+/, ""); print; exit}')"
	fi
	if [ -z "$KO_VERMAGIC" ]; then
		KO_VERMAGIC="$(grep -aoE 'vermagic=[^[:space:]]+' "$KO_PATH" 2>/dev/null | head -n 1 | sed 's/^vermagic=//')"
	fi
	echo "ko vermagic   : $KO_VERMAGIC"

	# vermagic prefix is everything before the first space
	KO_VM_PREFIX="${KO_VERMAGIC%% *}"
	echo "ko prefix     : $KO_VM_PREFIX"

	# A properly built GKI ko has a non-empty __versions section. modinfo
	# exposes its contents as `modversion:` lines. Empty modversions table
	# combined with a wrong vermagic prefix is the dangerous case where the
	# kernel may bypass version checks and let a binary-incompatible ko run.
	HAS_MODVERSIONS=0
	if [ -x /system/bin/modinfo ]; then
		if /system/bin/modinfo "$KO_PATH" 2>/dev/null | grep -q '^modversion:'; then
			HAS_MODVERSIONS=1
		fi
	fi
	echo "modversions   : $HAS_MODVERSIONS (1=has CRC table, 0=empty/missing)"

	# Verdict
	#
	# How insmod actually validates a ko on this kernel:
	#   * If both kernel and ko have CONFIG_MODVERSIONS=y AND the ko
	#     carries a non-empty __versions section, the kernel's
	#     same_magic() skips the version prefix of vermagic and only
	#     compares the suffix (" SMP preempt mod_unload modversions
	#     aarch64"). The actual ABI compatibility is then enforced
	#     per-symbol via __versions CRCs.
	#   * If __versions is empty, same_magic() compares the FULL
	#     vermagic string. A prefix mismatch then rejects the load
	#     with -ENOEXEC. But there are kernels in the wild (some OEM
	#     forks, some KSU-patched paths) where the vermagic check is
	#     looser, the ko ends up loaded WITHOUT any CRC validation,
	#     and a struct-layout mismatch then trips CFI/SCS during
	#     kretprobe registration -- this is the ishtar reboot path.
	#
	# Refusal rules:
	#   * empty __versions: refuse, full stop. The kernel cannot
	#     enforce ABI for us, and we have at least one device where
	#     this combination causes an instant reboot.
	#   * vermagic prefix mismatch AND empty __versions: refuse with
	#     two reasons.
	#   * vermagic prefix mismatch BUT __versions present: warn only.
	#     The kernel's CRC check will accept or reject correctly; we
	#     are not in a position to be more strict than that.
	VERDICT="ok"
	REASONS=""
	WARNINGS=""
	case "$KO_VM_PREFIX" in
		"$KERNEL_REL"|"")
			# exact match or no readable vermagic
			if [ -z "$KO_VM_PREFIX" ]; then
				VERDICT="refuse"
				REASONS="$REASONS unable_to_read_ko_vermagic"
			fi
			;;
		*)
			if [ "$HAS_MODVERSIONS" -eq 0 ]; then
				VERDICT="refuse"
				REASONS="$REASONS vermagic_prefix_mismatch"
			else
				WARNINGS="$WARNINGS vermagic_prefix_mismatch_but_modversions_present"
			fi
			;;
	esac
	if [ "$HAS_MODVERSIONS" -eq 0 ]; then
		VERDICT="refuse"
		REASONS="$REASONS empty_modversions_table"
	fi
	echo "verdict       : $VERDICT$REASONS"
	if [ -n "$WARNINGS" ]; then
		echo "warnings      :$WARNINGS"
	fi

	if [ "$VERDICT" = "refuse" ] && [ "$PROBE_FORCE_INSMOD" != "1" ]; then
		echo
		echo "REFUSED: kernel and ko ABI clearly mismatch; insmod skipped."
		echo "Set PROBE_FORCE_INSMOD=1 to override (NOT recommended; may reboot)."
		echo "RESULT: refused ($REASONS )"
		exit 0
	fi

	# Mark current dmesg position so we can extract only new lines.
	DMESG_BEFORE_MARKER="pathmask-probe-$$-$STAMP"
	log -p i -t pathmask-probe "$DMESG_BEFORE_MARKER" 2>/dev/null || true

	echo "--- insmod (target_paths=$PROBE_PATH scope_mode=global hide_dirents=0) ---"
	# Capture stderr separately so we can read the libc errno text.
	INSMOD_ERR_FILE="$OUT_DIR/_insmod.err"
	insmod "$KO_PATH" \
		target_paths="$PROBE_PATH" \
		hide_dirents=0 \
		scope_mode=global \
		deny_uids="" \
		2> "$INSMOD_ERR_FILE"
	INSMOD_RC=$?
	echo "insmod exit code: $INSMOD_RC"
	echo "--- insmod stderr ---"
	cat "$INSMOD_ERR_FILE" 2>/dev/null || true
	rm -f "$INSMOD_ERR_FILE" 2>/dev/null || true

	echo
	echo '--- /proc/modules after insmod ---'
	grep -E '^(pathmask|nohello|kernelsu) ' /proc/modules 2>/dev/null || true

	echo
	echo '--- /sys/module/pathmask/parameters after insmod ---'
	for f in /sys/module/${MODULE_NAME}/parameters/*; do
		[ -f "$f" ] && echo "$(basename "$f")=$(cat "$f" 2>/dev/null)"
	done

	echo
	echo '--- dmesg since marker ---'
	# Try awk first; fall back to grep + tail if marker not seen.
	if dmesg 2>/dev/null | grep -q "$DMESG_BEFORE_MARKER"; then
		dmesg 2>/dev/null | awk -v m="$DMESG_BEFORE_MARKER" '
			$0 ~ m { found=1; next }
			found { print }
		'
	else
		echo '(marker not visible in dmesg; showing last 80 relevant lines)'
		dmesg 2>/dev/null | grep -Ei 'pathmask|kernelsu|unknown symbol|disagrees about|invalid module|module_layout|kprobe|kretprobe|panic|oops|bug|version magic|key not available' | tail -n 80
	fi

	echo
	echo '--- logcat -d -s pathmask kernelsu (last 60) ---'
	logcat -d -s pathmask kernelsu 2>/dev/null | tail -n 60 || true

	# Cleanup: remove the module if we managed to load it.
	if grep -q "^${MODULE_NAME} " /proc/modules 2>/dev/null; then
		echo
		echo '--- cleanup: rmmod pathmask ---'
		rmmod "$MODULE_NAME" 2>&1
		echo "rmmod exit code: $?"
		echo '--- /proc/modules after rmmod ---'
		grep "^${MODULE_NAME} " /proc/modules 2>/dev/null || echo '(unloaded)'
	fi

	echo
	echo "RESULT: insmod_rc=$INSMOD_RC"
} > "$OUT_DIR/05-insmod-attempt.txt" 2>&1

# 6. Final dmesg snapshot for context
write_shell "06-dmesg-filtered.txt" "dmesg 2>/dev/null | grep -Ei 'pathmask|kernelsu|unknown symbol|disagrees about|invalid module|module_layout|kprobe|kretprobe|panic|oops|bug|version magic|key not available' | tail -n 200 || true"

cat > "$OUT_DIR/README.txt" <<'EOF'
PathMask loadability probe.

This package answers a single question: can pathmask.ko be loaded on this
device by a plain `insmod`, and if not, exactly why?

The most useful files are:
  05-insmod-attempt.txt  -- ABI sanity gate verdict + insmod result + dmesg
  02-policy.txt          -- sig_enforce / modules_disabled / kernel CONFIG
  03-vermagic.txt        -- ko vermagic vs running kernel uname
  04-symbols.txt         -- whether the symbols pathmask hooks still exist

Common readings:
  RESULT: refused (...)       The ABI sanity gate refused to insmod because
                              the ko is plainly incompatible with this
                              kernel. Look at the "verdict" line for the
                              specific reason(s).
  insmod_rc=0                 ko is fully compatible; the open-time failure
                              is somewhere in service.sh (e.g. deny mode
                              with no resolved UIDs).
  "Required key not available"
                              kernel enforces module signing, no insmod path
                              for unsigned ko.
  "disagrees about version of symbol X"
                              modversions CRC mismatch on symbol X; the ko
                              was built against a different KMI revision.
  "Unknown symbol X"
                              symbol X was trimmed from this OEM kernel.
  "Invalid module format"     vermagic mismatch (rare on GKI 5.x).
  device reboots during probe kretprobe registration tripped a vendor
                              watchdog (CFI/SCS abort on incompatible ko);
                              this is exactly what the ABI sanity gate is
                              designed to prevent.
EOF

if command -v tar >/dev/null 2>&1; then
	ARCHIVE="$OUT_DIR.tgz"
	(
		cd "$(dirname "$OUT_DIR")" &&
		tar -czf "$ARCHIVE" "$(basename "$OUT_DIR")"
	) 2>/dev/null && echo "Archive: $ARCHIVE"
fi

echo "Report directory: $OUT_DIR"
