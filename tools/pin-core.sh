#!/bin/sh
# Pin the xray core of the next gatygo release: write gatygo/files/lib/core.pin (the SHA256 of
# every archive a router may ask for, from the XTLS release's .dgst files) and move the unit
# test image and tools/xray-docker.sh to the same version, so CI tests this very core.
# Usage: tools/pin-core.sh v26.9.9      then run tests/run.sh and the e2e, commit, open a PR
set -eu
TAG=${1:?usage: tools/pin-core.sh <XTLS release tag, e.g. v26.9.9>}
cd "$(dirname "$0")/.."
BASE=https://github.com/XTLS/Xray-core/releases/download
PIN=gatygo/files/lib/core.pin

{
    echo "# The xray core of this gatygo release: SHA256 and path of every XTLS release archive a"
    echo "# router may ask for (core.sh). Written by tools/pin-core.sh, not by hand."
    for a in 32 64 arm32-v5 arm32-v6 arm32-v7a arm64-v8a mips32 mips32le mips64 mips64le riscv64 loong64; do
        sum=$(curl -fsSL --max-time 60 "$BASE/$TAG/Xray-linux-$a.zip.dgst" | sed -n 's/^SHA2-256= *//p')
        [ "${#sum}" -eq 64 ] || { echo "no SHA2-256 for Xray-linux-$a.zip in $TAG" >&2; exit 1; }
        echo "$sum  $TAG/Xray-linux-$a.zip"
    done
} > "$PIN.tmp"
mv "$PIN.tmp" "$PIN"

V=${TAG#v}
for f in tests/Dockerfile tools/xray-docker.sh; do
    sed -i.bak -E "s#(ghcr\.io/xtls/xray-core:)[0-9.]+#\1$V#" "$f" && rm -f "$f.bak"
    grep -q "ghcr.io/xtls/xray-core:$V" "$f"
done
echo "pinned $TAG: $PIN, tests/Dockerfile, tools/xray-docker.sh"
