#!/bin/sh
# The xray core. gatygo does not use the feed's xray-core package: every gatygo release pins one
# XTLS release (core.pin: a "SHA256  TAG/ARCHIVE" line per architecture, written by
# tools/pin-core.sh). The router downloads the archive for its architecture and unpacks the
# binary into gatygo's own directory. Nothing is unpacked or run before the SHA256 matched.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"

GATYGO_CORE_PIN=${GATYGO_CORE_PIN:-${GATYGO_LIB:-/usr/lib/gatygo}/core.pin}
GATYGO_CORE_BASE=${GATYGO_CORE_BASE:-https://github.com/XTLS/Xray-core/releases/download}

_gatygo_core_arch() {
    sed -n "s/^DISTRIB_ARCH='\(.*\)'/\1/p" "$GATYGO_SYSROOT/etc/openwrt_release" 2>/dev/null
}

# gatygo_core_asset — print "ARCHIVE BINARY" for this router's architecture: the XTLS release
# archive and the binary to take from it. Exit 1 when XTLS builds nothing for it.
gatygo_core_asset() {
    _gatygo_bin=xray
    case $(_gatygo_core_arch) in
        aarch64_*) _gatygo_a=arm64-v8a ;;
        x86_64) _gatygo_a=64 ;;
        i386_*) _gatygo_a=32 ;;
        arm_arm1176jzf-s_vfp) _gatygo_a=arm32-v6 ;;
        arm_*vfp* | arm_*neon*) _gatygo_a=arm32-v7a ;;
        # no FPU: the ARMv5 build is the soft-float one
        arm_*) _gatygo_a=arm32-v5 ;;
        # no FPU either, and OpenWrt's kernel does not emulate one: the archive has a second binary
        mipsel_*) _gatygo_a=mips32le _gatygo_bin=xray_softfloat ;;
        mips_*) _gatygo_a=mips32 _gatygo_bin=xray_softfloat ;;
        mips64el_*) _gatygo_a=mips64le ;;
        mips64_*) _gatygo_a=mips64 ;;
        riscv64_*) _gatygo_a=riscv64 ;;
        loongarch64_*) _gatygo_a=loong64 ;;
        *) return 1 ;;
    esac
    printf 'Xray-linux-%s.zip %s\n' "$_gatygo_a" "$_gatygo_bin"
}

# gatygo_core_pinned — print the pin for this router, "SHA256  TAG/ARCHIVE"; exit 1 when none
gatygo_core_pinned() {
    _gatygo_as=$(gatygo_core_asset) || return 1
    grep "^[0-9a-f]\{64\}  [^/ ]*/${_gatygo_as% *}\$" "$GATYGO_CORE_PIN" 2>/dev/null | head -n 1 | grep .
}

# gatygo_core_version — the pinned XTLS release, e.g. v26.9.9
gatygo_core_version() {
    grep -v '^#' "$GATYGO_CORE_PIN" 2>/dev/null | sed -n '1s#.*  \(.*\)/.*#\1#p'
}

# gatygo_core_ready — exit 0 iff the core in place is the pinned one
gatygo_core_ready() {
    [ -x "$GATYGO_CORE_DIR/xray" ] && _gatygo_p=$(gatygo_core_pinned) \
        && [ "$(cat "$GATYGO_CORE_DIR/pin" 2>/dev/null)" = "$_gatygo_p" ]
}

# _gatygo_core_install — download, check, unpack, try, swap. The archive goes to /tmp (RAM), the
# binary straight to its directory; the core in place is replaced only by one that runs.
_gatygo_core_install() {
    _gatygo_as=$(gatygo_core_asset) || {
        gatygo_log error "core: XTLS has no xray build for this architecture ($(_gatygo_core_arch))"
        return 1
    }
    _gatygo_p=$(gatygo_core_pinned) || {
        gatygo_log error "core: no xray release is pinned for ${_gatygo_as% *}"
        return 1
    }
    _gatygo_z=$(mktemp -d)
    gatygo_log info "core: downloading xray ${_gatygo_p##* }"
    curl -fsSL --proto '=http,https' --connect-timeout 15 --max-time 600 --retry 2 --retry-delay 5 \
        -o "$_gatygo_z/core.zip" "$GATYGO_CORE_BASE/${_gatygo_p##* }" 2>/dev/null
    _gatygo_rc=$?
    if [ "$_gatygo_rc" -ne 0 ]; then
        gatygo_log error "core: download failed (curl exit $_gatygo_rc)"
        rm -rf "$_gatygo_z"; return 1
    fi
    if [ "$(sha256sum < "$_gatygo_z/core.zip" | cut -d' ' -f1)" != "${_gatygo_p%% *}" ]; then
        gatygo_log error "core: the archive's SHA256 is not the pinned one; not unpacked"
        rm -rf "$_gatygo_z"; return 1
    fi
    mkdir -p "$GATYGO_CORE_DIR"
    unzip -p "$_gatygo_z/core.zip" "${_gatygo_as#* }" > "$GATYGO_CORE_DIR/xray.new" 2>/dev/null
    _gatygo_rc=$?
    rm -rf "$_gatygo_z"
    if [ "$_gatygo_rc" -ne 0 ] || [ ! -s "$GATYGO_CORE_DIR/xray.new" ]; then
        gatygo_log error "core: unpacking failed (is there room for $(_gatygo_core_arch)'s 35 MB binary?)"
        return 1
    fi
    chmod 755 "$GATYGO_CORE_DIR/xray.new"
    if ! "$GATYGO_CORE_DIR/xray.new" version >/dev/null 2>&1; then
        gatygo_log error "core: the downloaded xray does not run on this router"
        return 1
    fi
    mv "$GATYGO_CORE_DIR/xray.new" "$GATYGO_CORE_DIR/xray" && printf '%s\n' "$_gatygo_p" > "$GATYGO_CORE_DIR/pin"
}

# gatygo_core_ensure — make the core in place the pinned one. Prints ready (nothing to do),
# installed, or kept (it could not be replaced; the one in place still works). Exit 1 when
# there is no core to run.
gatygo_core_ensure() {
    # another binary was named: not gatygo's to manage (the unit tests run the image's xray)
    [ "$GATYGO_XRAY" = "$GATYGO_CORE_DIR/xray" ] || { echo ready; return 0; }
    if gatygo_core_ready; then echo ready; return 0; fi
    if _gatygo_core_install; then echo installed; return 0; fi
    rm -f "$GATYGO_CORE_DIR/xray.new"
    [ -x "$GATYGO_CORE_DIR/xray" ] || return 1
    gatygo_log warn "core: keeping the xray in place"
    echo kept
}
