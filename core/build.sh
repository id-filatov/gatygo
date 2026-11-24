#!/bin/sh
# Build gatygo's xray core: the XTLS release named in TAG plus the patches next to this script,
# with the Go and the build flags of that XTLS release (.github/workflows/release.yml of
# XTLS/Xray-core), into the archives a router asks for (gatygo/files/lib/core.sh): one
# Xray-linux-<name>.zip per architecture, with its .dgst, and README.md (the release notes).
# Usage: core/build.sh core-v26.11.9-1 OUT
#   ARCHS="arm64-v8a 64"   only these archives (default: all 12)
#   PATCHES=0              the XTLS source as it is, to compare with the XTLS build
#   BUILD=...              core.build (default: what XTLS gives, the short commit, then -gatygo.N)
#   GO_VERSION=1.27.3      the Go the XTLS release was built with (go version of its binary)
set -eu
TAG=${1:-} OUT=${2:-}
case $TAG in
    core-v*-[0-9]*) [ -n "$OUT" ] ;;
    *) false ;;
esac || { echo "usage: core/build.sh core-v<XTLS version>-<N> OUT" >&2; exit 2; }
DIR=$(cd "$(dirname "$0")" && pwd)
N=${TAG##*-} V=${TAG#core-v}
V=${V%-*}
ARCHS=${ARCHS:-32 64 arm32-v5 arm32-v6 arm32-v7a arm64-v8a mips32 mips32le mips64 mips64le riscv64 loong64}
export GOTOOLCHAIN=go${GO_VERSION:-1.27.3} CGO_ENABLED=0 TZ=UTC
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT INT TERM

sha256() { if command -v sha256sum >/dev/null; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -d' ' -f1; }

git clone -q --depth 1 --branch "v$V" https://github.com/XTLS/Xray-core.git "$SRC/xray"
cd "$SRC/xray"
BUILD=${BUILD:-$(git rev-parse --short=7 HEAD)-gatygo.$N}
[ "${PATCHES:-1}" = 0 ] || git -c user.name=gatygo -c user.email=gatygo@invalid am -q "$DIR"/patches/*.patch
go test ./app/observatory/... ./transport/internet/splithttp/...

cat > "$OUT/README.md" <<EOF
# Xray-core v$V for gatygo

The official Xray-core v$V (https://github.com/XTLS/Xray-core/tree/v$V) with the
patches in https://github.com/id-filatov/gatygo/tree/$TAG/core/patches applied,
built by core/build.sh of that tag with the Go (${GOTOOLCHAIN#go}) and the build flags of the XTLS release.

Xray-core is licensed under the Mozilla Public License 2.0 (LICENSE). The source of this build
is the XTLS tag above plus those patches.
EOF

for a in $ARCHS; do
    goarm='' gcflags=all=-l=4 soft=0
    case $a in
        32) goarch=386 ;;
        64) goarch=amd64 ;;
        arm32-v5) goarch=arm goarm=5 ;;
        arm32-v6) goarch=arm goarm=6 ;;
        arm32-v7a) goarch=arm goarm=7 ;;
        arm64-v8a) goarch=arm64 ;;
        # as XTLS: no "all=" for 32-bit MIPS, and a second, soft-float binary in the archive
        mips32) goarch=mips gcflags=-l=4 soft=1 ;;
        mips32le) goarch=mipsle gcflags=-l=4 soft=1 ;;
        mips64) goarch=mips64 ;;
        mips64le) goarch=mips64le ;;
        riscv64) goarch=riscv64 ;;
        loong64) goarch=loong64 ;;
        *) echo "no such archive: $a" >&2; exit 2 ;;
    esac
    pkg=$SRC/pkg-$a
    mkdir -p "$pkg"
    for bin in xray $([ "$soft" = 1 ] && echo xray_softfloat); do
        gomips=''
        [ "$bin" = xray ] || gomips=softfloat
        GOOS=linux GOARCH=$goarch GOARM=$goarm GOMIPS=$gomips go build -o "$pkg/$bin" -trimpath -buildvcs=false \
            -gcflags="$gcflags" -ldflags="-X github.com/xtls/xray-core/core.build=$BUILD -s -w -buildid=" ./main
    done
    cp LICENSE "$OUT/README.md" "$pkg/"
    touch -t 202601010000 "$pkg"/*
    rm -f "$OUT/Xray-linux-$a.zip"
    (cd "$pkg" && zip -q -9 -X -r "$OUT/Xray-linux-$a.zip" .)
    printf 'SHA2-256= %s\n' "$(sha256 "$OUT/Xray-linux-$a.zip")" > "$OUT/Xray-linux-$a.zip.dgst"
    echo "Xray-linux-$a.zip"
done
