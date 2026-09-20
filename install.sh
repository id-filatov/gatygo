#!/bin/sh
# Install gatygo on an OpenWrt 25.12 router: the two packages and, through apk, everything they
# need (jq, curl, ca-bundle, unzip, ip-full, kmod-nft-tproxy). A stock image has the rest:
# dnsmasq, firewall4 with nftables, rpcd and LuCI. The xray core is not a package: gatygo
# downloads the release pinned in it when it first starts, about 35 MB on the overlay.
#
# Everything that can refuse a router is checked before anything is installed. Nothing is
# switched on and no subscription is written: that is done in LuCI afterwards.
#
#   install.sh                                       the latest release
#   install.sh --version v20260918.1851              that release
#   install.sh gatygo-*.apk luci-app-gatygo-*.apk    local files, nothing is downloaded
#
# GH_TOKEN (or GITHUB_TOKEN) is used when set: the releases of a private repository need one.
set -eu

REPO=${GATYGO_REPO:-id-filatov/gatygo}
API="https://api.github.com/repos/$REPO/releases"
RAW="https://raw.githubusercontent.com/$REPO"
TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
# the xray core (35 MB) plus the geo files and the packages themselves; a core already in
# place is not downloaded again
NEED_KB=61440
NEED_KB_WITH_CORE=20480
CONFLICTS="luci-app-passwall luci-app-passwall2 luci-app-openclash luci-app-homeproxy"
# what gatygo's Makefile asks apk for. apk resolves the real list when the package is installed;
# this one is here to find out early whether this router's feeds can serve it at all.
DEPS="unzip jq curl ca-bundle ip-full kmod-nft-tproxy"

say() { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
install.sh [--version <tag>] [<gatygo.apk> <luci-app-gatygo.apk>]
  no arguments   install the latest release from GitHub
  --version TAG  install that release (e.g. v20260918.1851)
  two .apk paths install those files, download nothing
  GH_TOKEN       used when set; a private repository's releases need it
USAGE
}

VERSION=''
FILES=''
while [ $# -gt 0 ]; do
    case $1 in
        --version) [ $# -ge 2 ] || die "--version needs a release tag"; VERSION=$2; shift 2 ;;
        --version=*) VERSION=${1#*=}; shift ;;
        -h | --help) usage; exit 0 ;;
        -*) die "unknown option $1 (--help)" ;;
        *) FILES="$FILES $1"; shift ;;
    esac
done

# --- getting bytes off the internet -------------------------------------------------------------
# A stock image has uclient-fetch (as `wget`) and no curl. A token has to go in a header, which
# only curl can send, so curl is installed first when there is one.

# _to_github URL — exit 0 when URL is one of GitHub's own: the token goes nowhere else
_to_github() {
    case $1 in
        https://api.github.com/* | https://raw.githubusercontent.com/* | https://github.com/*) return 0 ;;
        *) return 1 ;;
    esac
}

http_get() {
    if [ -n "$TOKEN" ] && _to_github "$1"; then
        curl -fsSL --connect-timeout 15 --max-time 120 -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $TOKEN" "$1" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 120 "$1" 2>/dev/null
    else
        wget -qO- -T 15 "$1" 2>/dev/null
    fi
}

http_to_file() {
    if [ -n "$TOKEN" ] && _to_github "$1"; then
        curl -fsSL --connect-timeout 15 --max-time 300 -H "Accept: application/octet-stream" \
            -H "Authorization: Bearer $TOKEN" -o "$2" "$1" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 300 -o "$2" "$1" 2>/dev/null
    else
        wget -qO "$2" -T 60 "$1" 2>/dev/null
    fi
}

# asset_url JSON PREFIX — the download URL of the release asset whose name starts with PREFIX.
# With a token the API asset URL is the one that serves the bytes; without, the browser one.
asset_url() {
    if [ -n "$TOKEN" ]; then
        printf '%s' "$1" | jq -r --arg p "$2" 'first(.assets[] | select(.name | startswith($p)) | .url) // empty'
    else
        printf '%s' "$1" | jq -r --arg p "$2" 'first(.assets[] | select(.name | startswith($p)) | .browser_download_url) // empty'
    fi
}

# official_kmods_url — the feed downloads.openwrt.org keeps for this release, target and kernel
# build, or nothing. An image built by hand carries no kmods feed of its own, and this one fits
# it only when its kernel is the official build; apk says so itself, by the version of the
# `kernel` package the modules depend on.
official_kmods_url() {
    _t=$(sed -n "s/^DISTRIB_TARGET='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null)
    [ -n "$_t" ] && [ -n "$RELEASE" ] || return 1
    _base="https://downloads.openwrt.org/releases/$RELEASE/targets/$_t/kmods"
    _dir=$(http_get "$_base/" | grep -oE "$(uname -r)-[0-9]+-[0-9a-f]+/" | head -n 1)
    [ -n "$_dir" ] || return 1
    printf '%s/%spackages.adb\n' "$_base" "$_dir"
}

# explain_apk_failure OUTPUT — say in words why apk could not select packages. A kernel module
# comes from the feed of one exact kernel build, and an image built by hand asks for a build
# downloads.openwrt.org does not carry: then no kmod installs on it at all.
explain_apk_failure() {
    _missing=$(printf '%s' "$1" | sed -n 's/^  \([^ ]*\) (no such package):$/\1/p' | tr '\n' ' ' | sed 's/ *$//')
    if [ -z "$_missing" ]; then
        printf '%s\n' "$1" >&2
        [ -z "${KMODS_X:-}" ] || die "apk would not take the modules from
    $KMODS_X
  They are built for the kernel of the official image; this one runs a kernel of its own
  build. Build the packages into the image ($DEPS) and run this script again."
        die "apk refused the packages"
    fi
    _kmods=$(grep -h kmods /etc/apk/repositories.d/* 2>/dev/null | head -n 1)
    case " $_missing " in
        *" kmod-"*)
            if [ -n "${KMODS_X:-}" ]; then
                _why="the feed of this release, target and kernel version,
    $KMODS_X
  does not serve it either: this image runs a kernel of its own build, and a module
  built against another one does not load."
            elif [ -z "$_kmods" ]; then
                _why="this image carries no kmods feed, nor does downloads.openwrt.org
  have one for this release, target and kernel version: no kernel module can be
  installed on this router as it is."
            elif case ${BAD_FEEDS:-} in *"$_kmods"*) true ;; *) false ;; esac; then
                _why="its index did not load:
    $_kmods
  An image built by hand runs a kernel downloads.openwrt.org builds no modules for."
            else
                _why="the kmods feed it has carries no such module:
    $_kmods"
            fi
            die "this router's feeds have no: $_missing
  A kernel module comes from the feed of one exact kernel build, and $_why
  Either build the packages into the image ($DEPS)
  and run this script again, or add the kmods feed of the build this image came from." ;;
        *) die "this router's feeds have no: $_missing" ;;
    esac
}

# --- 1. checks: nothing is installed until all of them have passed ------------------------------

[ "$(id -u)" = 0 ] || die "run as root"
command -v apk >/dev/null 2>&1 || die "no apk: gatygo needs OpenWrt 25.12 or newer"

RELEASE=$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null || true)
ARCH=$(sed -n "s/^DISTRIB_ARCH='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null || true)
case ${RELEASE:-unknown} in
    25.12*) ;;
    *) [ "${GATYGO_ANY_RELEASE:-0}" = 1 ] \
        || die "OpenWrt ${RELEASE:-unknown} is not what gatygo is tested on (25.12); GATYGO_ANY_RELEASE=1 installs anyway" ;;
esac

for _p in $CONFLICTS; do
    if apk info -e "$_p" >/dev/null 2>&1; then
        die "$_p is installed: it owns the same transparent proxy rules; remove it first"
    fi
done

say "gatygo installer (OpenWrt ${RELEASE:-unknown}, ${ARCH:-unknown})"
say ""
say "checks:"

# A feed that does not load is not fatal by itself: what matters is whether the packages gatygo
# needs can still be selected, which the next check answers. apk names the feeds it did load as
# well, so only its warnings say which one failed.
UPDATE_OUT=$(apk update 2>&1) || true
BAD_FEEDS=$(printf '%s' "$UPDATE_OUT" | grep '^WARNING' | grep -oE 'https://[^ ]*\.adb' | sort -u || true)
for _u in $BAD_FEEDS; do warn "this feed did not load: $_u"; done

APK_X=''
# shellcheck disable=SC2086
if ! SIM_OUT=$(apk add --simulate $DEPS 2>&1); then
    KMODS_X=$(official_kmods_url || true)
    # shellcheck disable=SC2086
    if [ -n "$KMODS_X" ] && SIM_OUT=$(apk add --simulate -X "$KMODS_X" $DEPS 2>&1); then
        APK_X=$KMODS_X
        note "this image has no kmods feed; the official one for its kernel serves the modules:"
        note "  $KMODS_X"
    else
        explain_apk_failure "$SIM_OUT"
    fi
fi
note "the feeds serve what gatygo depends on: $DEPS"

# a token can only be sent by curl
if [ -n "$TOKEN" ] && ! command -v curl >/dev/null 2>&1; then
    apk add curl ca-bundle >/dev/null 2>&1 || die "could not install curl, which GH_TOKEN needs"
fi

MOUNT=/overlay
[ -d /overlay ] || MOUNT=/
FREE_KB=$(df -k "$MOUNT" 2>/dev/null | awk 'NR > 1 { print $4; exit }')
case ${FREE_KB:-0} in
    *[!0-9]* | '') FREE_KB=0 ;;
esac
[ -x /usr/lib/gatygo/core/xray ] && NEED_KB=$NEED_KB_WITH_CORE
if [ "$FREE_KB" -ge "$NEED_KB" ]; then
    note "free space: $((FREE_KB / 1024)) MB on $MOUNT"
elif [ "$NEED_KB" = "$NEED_KB_WITH_CORE" ]; then
    warn "only $((FREE_KB / 1024)) MB free on $MOUNT: the geo files and an updated core need room"
else
    warn "only $((FREE_KB / 1024)) MB free on $MOUNT: the xray core alone takes 35 MB"
fi

if [ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq running >/dev/null 2>&1; then
    note "dnsmasq is running: gatygo will point it at xray's DNS"
else
    warn "dnsmasq is not running: gatygo resolves the LAN's names through it"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
GATYGO_APK='' LUCI_APK='' TAG='' CORE=''

if [ -n "$FILES" ]; then
    for _f in $FILES; do
        [ -f "$_f" ] || die "no such file: $_f"
        case $(basename "$_f") in
            luci-app-gatygo-*.apk) LUCI_APK=$_f ;;
            gatygo-*.apk) GATYGO_APK=$_f ;;
            *) die "not a gatygo package: $_f" ;;
        esac
    done
    [ -n "$GATYGO_APK" ] && [ -n "$LUCI_APK" ] || die "give both files: gatygo-*.apk and luci-app-gatygo-*.apk"
    note "packages: $GATYGO_APK, $LUCI_APK"
else
    # jq reads the release. It and curl are gatygo's own dependencies, and the check above has
    # just found both in the feeds.
    apk add curl jq ca-bundle >/dev/null 2>&1 || die "could not install curl, jq and ca-bundle"

    if [ -n "$VERSION" ]; then _url="$API/tags/$VERSION"; else _url="$API/latest"; fi
    if [ -n "$TOKEN" ]; then _hint="is GH_TOKEN valid, and does it reach $REPO?"; else _hint="a private repository needs GH_TOKEN"; fi
    JSON=$(http_get "$_url") || die "GitHub served no release: $_hint"
    TAG=$(printf '%s' "$JSON" | jq -r '.tag_name // empty')
    [ -n "$TAG" ] || die "GitHub served no release: $_hint"
    GATYGO_URL=$(asset_url "$JSON" gatygo-)
    LUCI_URL=$(asset_url "$JSON" luci-app-gatygo-)
    [ -n "$GATYGO_URL" ] && [ -n "$LUCI_URL" ] || die "release $TAG has no .apk files attached"
    note "release $TAG of $REPO"

    # Is there an xray build for this router? The release's own core.sh answers, so the list of
    # architectures stays in one place; before an install that means fetching it and the pin.
    mkdir -p "$TMP/lib"
    if http_to_file "$RAW/$TAG/gatygo/files/lib/core.sh" "$TMP/lib/core.sh" \
        && http_to_file "$RAW/$TAG/gatygo/files/lib/core.pin" "$TMP/lib/core.pin"; then
        # core.sh sources it; nothing in it is needed to read the pin
        : > "$TMP/lib/config.sh"
        CORE=$(sh -c "GATYGO_LIB=$TMP/lib; . $TMP/lib/core.sh; gatygo_core_pinned >/dev/null && gatygo_core_version" 2>/dev/null || true)
        [ -n "$CORE" ] || die "XTLS builds no xray for ${ARCH:-this architecture}: gatygo cannot run on this router"
        note "xray core $CORE is pinned for ${ARCH:-this architecture}"
    else
        warn "could not read the release's core.pin: the xray core is checked after the install"
    fi
fi

# --- 2. install ---------------------------------------------------------------------------------

say ""
if [ -z "$FILES" ]; then
    say "downloading $TAG"
    GATYGO_APK=$TMP/gatygo.apk LUCI_APK=$TMP/luci-app-gatygo.apk
    http_to_file "$GATYGO_URL" "$GATYGO_APK" || die "could not download the gatygo package"
    http_to_file "$LUCI_URL" "$LUCI_APK" || die "could not download the luci-app-gatygo package"
    [ -s "$GATYGO_APK" ] && [ -s "$LUCI_APK" ] || die "the downloaded packages are empty"
fi

say "installing gatygo and luci-app-gatygo"
# the packages are signed with the build key, which the router does not have
if [ -n "$APK_X" ]; then set -- -X "$APK_X"; else set --; fi
if ! ADD_OUT=$(apk add --allow-untrusted "$@" "$GATYGO_APK" "$LUCI_APK" 2>&1); then
    explain_apk_failure "$ADD_OUT"
fi
printf '%s\n' "$ADD_OUT" | sed -n 's/^(\([0-9/]*\)) \(Installing.*\)$/  \2/p'

# --- 3. what the router looks like now ------------------------------------------------------------

say ""
say "result:"
if /etc/init.d/gatygo running >/dev/null 2>&1; then
    note "gatygo $(cat /usr/lib/gatygo/version 2>/dev/null || echo '?') is running"
else
    note "gatygo $(cat /usr/lib/gatygo/version 2>/dev/null || echo '?') installed, not started"
fi

if [ -z "$CORE" ]; then
    if CORE=$(sh -c '. /usr/lib/gatygo/core.sh; gatygo_core_pinned >/dev/null && gatygo_core_version' 2>/dev/null) && [ -n "$CORE" ]; then
        note "xray core $CORE is pinned for ${ARCH:-this architecture}"
    else
        warn "no xray core is pinned for ${ARCH:-this architecture}: gatygo cannot run here (apk del luci-app-gatygo gatygo)"
    fi
fi

if printf 'table inet gatygo_probe {\n chain c {\n  type filter hook prerouting priority mangle;\n  meta l4proto tcp tproxy ip to 127.0.0.1:12345 accept\n }\n}\n' | nft -c -f - >/dev/null 2>&1; then
    note "nftables takes the tproxy rules"
else
    warn "nftables does not take a tproxy rule: the LAN will not be proxied"
fi

say ""
if /etc/init.d/gatygo running >/dev/null 2>&1; then
    say "Nothing else to do: the tunnel is up (gatygo status)."
else
    say "Next: LuCI -> Services -> gatygo -> paste the subscription URL -> Save & Apply."
    say "From the shell instead:"
    note "uci set gatygo.main.sub_url='<url>'; uci commit gatygo; /etc/init.d/gatygo start"
fi
