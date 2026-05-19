#!/usr/bin/env bash
# Build pathmask.ko for ONE KMI locally (using the same DDK image CI uses),
# then run the same ABI sanity gate, and produce a KernelSU zip.
#
# Usage:
#   tools/build_one.sh <kmi> [<ddk_release>]
#
# Examples:
#   tools/build_one.sh android13-5.15
#   tools/build_one.sh android13-5.15 20260520
#
# Requirements: docker (or podman with docker shim), zip, sh.

set -euo pipefail

KMI="${1:-}"
DDK_RELEASE="${2:-20260313}"

if [ -z "$KMI" ]; then
    echo "Usage: $0 <kmi> [<ddk_release>]" >&2
    exit 2
fi

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE="ghcr.io/ylarod/ddk-min:${KMI}-${DDK_RELEASE}"
OUT_DIR="$REPO_ROOT/out"
KO_BASENAME="${KMI}_pathmask.ko"
KO_PATH="$OUT_DIR/$KO_BASENAME"

mkdir -p "$OUT_DIR"

echo "=== Building $KO_BASENAME using $IMAGE ==="
docker run --rm --privileged \
    -v "$REPO_ROOT":/work \
    -w /work/kernel \
    "$IMAGE" \
    sh -c '
        set -eu
        echo "container kernel headers:"
        ls -la "$KDIR" || true
        CONFIG_KSU=m CC=clang make
    '

# The Makefile drops pathmask.ko into kernel/.
SRC_KO="$REPO_ROOT/kernel/pathmask.ko"
if [ ! -f "$SRC_KO" ]; then
    echo "Build did not produce $SRC_KO" >&2
    exit 1
fi
cp "$SRC_KO" "$KO_PATH"

# Strip the same way CI does.
if command -v llvm-strip >/dev/null 2>&1; then
    llvm-strip -d "$KO_PATH"
elif command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
    aarch64-linux-gnu-strip -d "$KO_PATH"
fi
echo "Built: $KO_PATH ($(du -h "$KO_PATH" | cut -f1))"

# === ABI sanity gate (mirrors CI) ===
echo
echo "=== Verifying ABI ==="
KMI_TAG="$(printf '%s' "$KMI" | cut -d- -f1)" # e.g. android13

VM=""
if command -v modinfo >/dev/null 2>&1; then
    VM="$(modinfo "$KO_PATH" 2>/dev/null | awk '/^vermagic:/ {sub(/^vermagic:[[:space:]]+/, ""); print; exit}')"
fi
if [ -z "$VM" ]; then
    VM="$(strings "$KO_PATH" | grep -m1 '^vermagic=' | sed 's/^vermagic=//')"
fi
echo "vermagic: $VM"

FAIL=0
case "$VM" in
    *"${KMI_TAG}-"*) echo "PASS: vermagic carries KMI tag '${KMI_TAG}-'" ;;
    *) echo "FAIL: vermagic does not contain '${KMI_TAG}-'"; FAIL=1 ;;
esac

case "$VM" in
    *-dirty*|*"_r00"*)
        echo "FAIL: vermagic contains -dirty / _r00 marker (non-KMI tree)"
        FAIL=1
    ;;
esac

if command -v llvm-readelf >/dev/null 2>&1; then
    READELF=llvm-readelf
elif command -v readelf >/dev/null 2>&1; then
    READELF=readelf
else
    READELF=""
fi

if [ -n "$READELF" ]; then
    VS_HEX="$($READELF -SW "$KO_PATH" 2>/dev/null | awk '/__versions/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9a-fA-F]{6,}$/) {print $i; exit}}')"
    [ -z "$VS_HEX" ] && VS_HEX=0
    VS_DEC=$((16#$VS_HEX))
    echo "__versions size: $VS_HEX ($VS_DEC bytes)"
    if [ "$VS_DEC" -le 0 ]; then
        echo "FAIL: __versions is empty"
        FAIL=1
    else
        echo "PASS: __versions is non-empty"
    fi
fi

if command -v modinfo >/dev/null 2>&1; then
    MV_COUNT="$(modinfo "$KO_PATH" 2>/dev/null | grep -c '^modversion:' || true)"
    echo "modversion: lines = $MV_COUNT"
    if [ "$MV_COUNT" -lt 1 ]; then
        echo "FAIL: no modversion: lines"
        FAIL=1
    else
        echo "PASS: $MV_COUNT modversion entries"
    fi
fi

if [ "$FAIL" -ne 0 ]; then
    echo
    echo "ABI sanity gate FAILED. Refusing to package."
    echo "Try a different ddk_release, e.g.:"
    echo "  tools/pick_ddk_tag.sh $KMI"
    exit 1
fi

echo
echo "=== Packaging KernelSU zip ==="
ZIP_OUT="$OUT_DIR/${KMI}_pathmask-ksu.zip"
UPDATE_JSON_URL="https://raw.githubusercontent.com/Andrea-lyz/LKM-PathMask/main/update/${KMI}.json" \
    sh "$REPO_ROOT/tools/package_ksu.sh" "$KO_PATH" "$ZIP_OUT"

echo
echo "Done."
echo "  ko : $KO_PATH"
echo "  zip: $ZIP_OUT"
