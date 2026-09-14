#!/bin/sh
# Build gatygo packages with the official OpenWrt SDK container.
# The packages are noarch (PKGARCH:=all), so the x86_64 SDK output installs on any target.
#
# The SDK container is kept between runs (name: gatygo-sdk). Only the requested packages and
# their dependencies are selected, otherwise the kmod-nft-tproxy dependency makes the SDK
# re-package every kernel module it ships on each run (30+ minutes under x86_64 emulation).
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
docker exec -i -e PACKAGES="${*:-gatygo}" "$NAME" bash -s <<'EOF'
	set -eo pipefail
	cd /builder
	echo "src-link gatygo /feed" > feeds.conf
	./scripts/feeds update -a >/dev/null
	./scripts/feeds install -a -p gatygo >/dev/null
	# package/<pkg>/compile always drags package/kernel/linux/compile along, which packages every
	# selected kernel module. The SDK declares all ~1100 of them as prompt-less "default m" symbols
	# in Config-build.in (no dependency info there), so .config cannot switch them off. Keep
	# "default m" only for the modules our packages need, transitively, and flip the rest to n.
	[ -e Config-build.in.orig ] || cp Config-build.in Config-build.in.orig
	make prepare-tmpinfo >/dev/null 2>&1
	KMODS=$(awk -v want="$PACKAGES" '
		/^Package: / { p = $2 }
		/^Depends: / { for (i = 2; i <= NF; i++) { d = $i; sub(/^\+/, "", d); sub(/^.*:/, "", d); if (d !~ /^@/) dep[p] = dep[p] " " d } }
		END {
			n = split(want, q, " "); for (i = 1; i <= n; i++) seen[q[i]] = 1
			while (n > 0) { m = split(dep[q[n--]], ds, " "); for (j = 1; j <= m; j++) if (!(ds[j] in seen)) { seen[ds[j]] = 1; q[++n] = ds[j] } }
			for (s in seen) if (s ~ /^kmod-/) print s
		}' tmp/info/.packageinfo-*)
	awk -v keep=" $(echo $KMODS) " '
		/^config PACKAGE_kmod-/ { off = !index(keep, " " substr($2, 9) " ") }
		/^config / && !/^config PACKAGE_kmod-/ { off = 0 }
		off && /^[ \t]*default m$/ { sub(/default m/, "default n") }
		{ print }' Config-build.in.orig > Config-build.in
	{
		echo "# CONFIG_ALL is not set"
		for p in $PACKAGES; do echo "CONFIG_PACKAGE_$p=m"; done
	} > .config
	make defconfig >/dev/null 2>&1
	echo "kernel modules selected: $(grep '^CONFIG_PACKAGE_kmod-.*=m' .config | cut -d= -f1 | cut -c16- | tr '\n' ' ')"
	for p in $PACKAGES; do make -j"$(nproc)" "package/$p/compile" 2>&1 | tail -5; done
	ls -la bin/packages/*/gatygo/
EOF
