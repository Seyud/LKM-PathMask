#!/usr/bin/env bash
# List available ghcr.io/ylarod/ddk-min tags that match a given KMI prefix.
#
# Usage:
#   tools/pick_ddk_tag.sh android13-5.15
#
# Requires curl + jq. Picks an anonymous bearer token from ghcr the same way
# `docker pull` would, then queries the public tags list and filters by KMI.

set -euo pipefail

KMI="${1:-android13-5.15}"
IMAGE="ylarod/ddk-min"
REGISTRY="ghcr.io"

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required (apt install jq / brew install jq)" >&2
    exit 1
fi

TOKEN=$(curl -fsSL "https://ghcr.io/token?scope=repository:${IMAGE}:pull" | jq -r .token)
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "failed to obtain ghcr bearer token" >&2
    exit 1
fi

echo "Querying tags for $REGISTRY/$IMAGE matching '${KMI}-*'..."

# /v2/<image>/tags/list pages 1000 entries at a time. ghcr respects ?n= up
# to a few hundred; we paginate via Link headers if needed.
URL="https://${REGISTRY}/v2/${IMAGE}/tags/list?n=200"
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT

while [ -n "$URL" ]; do
    HDR=$(mktemp)
    BODY=$(mktemp)
    curl -fsSL -D "$HDR" -o "$BODY" -H "Authorization: Bearer $TOKEN" "$URL"
    jq -r '.tags[]?' "$BODY" >> "$RESULTS"
    NEXT=$(awk '
        BEGIN { IGNORECASE=1 }
        /^link:/ {
            for (i=2; i<=NF; i++) {
                if (match($i, /<([^>]+)>/, m)) {
                    if ($0 ~ /rel="?next"?/) print m[1]
                }
            }
        }' "$HDR" || true)
    rm -f "$HDR" "$BODY"
    URL="$NEXT"
done

# Filter, sort by date suffix descending.
echo
echo "Matching tags (newest first):"
grep -E "^${KMI}-[0-9]{6,8}$" "$RESULTS" | sort -t- -k3 -r | head -n 20 || {
    echo "(none found)"
    echo
    echo "First 20 raw tags returned by ghcr (for debugging):"
    head -n 20 "$RESULTS"
}
