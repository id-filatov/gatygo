#!/bin/sh
# Build gatygo packages with the official OpenWrt SDK container.
# The packages are noarch (PKGARCH:=all), so the x86_64 SDK output installs on any target.
#
# The SDK container is kept between runs (name: gatygo-sdk): the first build also packages
# every kernel module the SDK ships (our package depends on kmod-nft-tproxy), which takes
# 15+ minutes under x86_64 emulation on Apple silicon; later builds take seconds.
#
# Usage: tools/build-apk.sh [package ...]     default: gatygo
#        tools/build-apk.sh --reset            drop the container (next run starts from scratch)
# Output: bin/packages/x86_64/gatygo/<package>-<version>-r<rel>.apk
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK_IMAGE=openwrt/sdk:x86_64-25.12.5
NAME=gatygo-sdk

if [ "${1:-}" = --reset ]; then
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	echo "container $NAME removed"
	exit 0
fi

mkdir -p "$ROOT/bin"
if ! docker inspect "$NAME" >/dev/null 2>&1; then
	docker create --name "$NAME" --platform linux/amd64 \
		-v "$ROOT:/feed:ro" -v "$ROOT/bin:/builder/bin" \
		"$SDK_IMAGE" sleep infinity >/dev/null
fi
docker start "$NAME" >/dev/null
docker exec -e PACKAGES="${*:-gatygo}" "$NAME" bash -c '
	set -e
	cd /builder
	echo "src-link gatygo /feed" > feeds.conf
	./scripts/feeds update -a >/dev/null
	./scripts/feeds install -a -p gatygo >/dev/null
	make defconfig >/dev/null
	for p in $PACKAGES; do make -j"$(nproc)" "package/$p/compile" 2>&1 | tail -5; done
	ls -la bin/packages/*/gatygo/'
