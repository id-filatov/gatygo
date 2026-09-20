#!/bin/sh
# Install gatygo on a stock OpenWrt 25.12 router: the two packages and, through apk, everything
# they need (jq, curl, ca-bundle, unzip, ip-full, kmod-nft-tproxy). A stock image already has the
# rest: dnsmasq, firewall4 with nftables, rpcd and LuCI. The xray core is not a package: gatygo
# downloads the release pinned in it when it first starts, about 35 MB on the overlay.
#
# Nothing is switched on and no subscription is written: that is done in LuCI afterwards.
#
#   install.sh                                       the latest release
#   install.sh --version v20260918.1851              that release
#   install.sh gatygo-*.apk luci-app-gatygo-*.apk    local files, nothing is downloaded
#
# GH_TOKEN (or GITHUB_TOKEN) is used when set: the releases of a private repository need one.
set -eu

REPO=${GATYGO_REPO:-id-filatov/gatygo}
API="https://api.github.com/repos/$REPO/releases"
TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
# the xray core (35 MB) plus the geo files and the packages themselves; a core already in
# place is not downloaded again
NEED_KB=61440
NEED_KB_WITH_CORE=20480
CONFLICTS="luci-app-passwall luci-app-passwall2 luci-app-openclash luci-app-homeproxy"

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

# --- the router has to be one gatygo runs on --------------------------------------------------

[ "$(id -u)" = 0 ] || die "run as root"
command -v apk >/dev/null 2>&1 || die "no apk: gatygo needs OpenWrt 25.12 or newer"

RELEASE=$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null || true)
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

MOUNT=/overlay
[ -d /overlay ] || MOUNT=/
FREE_KB=$(df -k "$MOUNT" 2>/dev/null | awk 'NR > 1 { print $4; exit }')
case ${FREE_KB:-0} in
    *[!0-9]* | '') FREE_KB=0 ;;
esac

# --- the packages -----------------------------------------------------------------------------

fetch_ok() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --connect-timeout 8 --max-time 20 -o /dev/null "$1" 2>/dev/null
    else
        uclient-fetch -q -T 8 -O /dev/null "$1" 2>/dev/null
    fi
}

gh_api() {
    if [ -n "$TOKEN" ]; then
        curl -fsSL --connect-timeout 15 --max-time 60 -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $TOKEN" "$1" 2>/dev/null
    else
        curl -fsSL --connect-timeout 15 --max-time 60 -H "Accept: application/vnd.github+json" "$1" 2>/dev/null
    fi
}

gh_download() {
    if [ -n "$TOKEN" ]; then
        curl -fsSL --connect-timeout 15 --max-time 300 -H "Accept: application/octet-stream" \
            -H "Authorization: Bearer $TOKEN" -o "$2" "$1" 2>/dev/null
    else
        curl -fsSL --connect-timeout 15 --max-time 300 -o "$2" "$1" 2>/dev/null
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

say "gatygo installer (OpenWrt ${RELEASE:-unknown}, $(sed -n "s/^DISTRIB_ARCH='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null))"

if [ -n "$FILES" ]; then
    GATYGO_APK='' LUCI_APK=''
    for _f in $FILES; do
        [ -f "$_f" ] || die "no such file: $_f"
        case $(basename "$_f") in
            luci-app-gatygo-*.apk) LUCI_APK=$_f ;;
            gatygo-*.apk) GATYGO_APK=$_f ;;
            *) die "not a gatygo package: $_f" ;;
        esac
    done
    [ -n "$GATYGO_APK" ] && [ -n "$LUCI_APK" ] || die "give both files: gatygo-*.apk and luci-app-gatygo-*.apk"
    say "packages: $GATYGO_APK, $LUCI_APK"
fi

say "updating the package lists"
apk update >/dev/null || die "apk update failed: the router has no way to the OpenWrt feeds"

if [ -z "$FILES" ]; then
    # curl and jq are gatygo's own dependencies; they are needed before it to read the release
    say "installing curl, jq and ca-bundle"
    apk add curl jq ca-bundle >/dev/null || die "could not install curl, jq and ca-bundle"

    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT INT TERM
    if [ -n "$VERSION" ]; then URL="$API/tags/$VERSION"; else URL="$API/latest"; fi
    say "reading ${VERSION:-the latest release} of $REPO"
    if [ -n "$TOKEN" ]; then _hint="is GH_TOKEN valid, and does it reach $REPO?"; else _hint="a private repository needs GH_TOKEN"; fi
    JSON=$(gh_api "$URL") || die "GitHub served no release: $_hint"
    TAG=$(printf '%s' "$JSON" | jq -r '.tag_name // empty')
    [ -n "$TAG" ] || die "the answer from GitHub carries no release"

    GATYGO_URL=$(asset_url "$JSON" gatygo-)
    LUCI_URL=$(asset_url "$JSON" luci-app-gatygo-)
    [ -n "$GATYGO_URL" ] && [ -n "$LUCI_URL" ] || die "release $TAG has no .apk files attached"

    say "downloading $TAG"
    GATYGO_APK=$TMP/gatygo.apk LUCI_APK=$TMP/luci-app-gatygo.apk
    gh_download "$GATYGO_URL" "$GATYGO_APK" || die "could not download the gatygo package"
    gh_download "$LUCI_URL" "$LUCI_APK" || die "could not download the luci-app-gatygo package"
    [ -s "$GATYGO_APK" ] && [ -s "$LUCI_APK" ] || die "the downloaded packages are empty"
fi

say "installing gatygo and luci-app-gatygo"
# the packages are signed with the build key, which the router does not have
apk add --allow-untrusted "$GATYGO_APK" "$LUCI_APK" || die "apk refused the packages"

# --- what the router looks like now ------------------------------------------------------------

say ""
say "checks:"
if /etc/init.d/gatygo running >/dev/null 2>&1; then
    note "gatygo $(cat /usr/lib/gatygo/version 2>/dev/null || echo '?') is running"
else
    note "gatygo $(cat /usr/lib/gatygo/version 2>/dev/null || echo '?') installed, not started"
fi

if CORE=$(sh -c '. /usr/lib/gatygo/core.sh; gatygo_core_pinned >/dev/null && gatygo_core_version' 2>/dev/null) && [ -n "$CORE" ]; then
    note "xray core $CORE is pinned for this architecture"
else
    warn "no xray core is pinned for this architecture: gatygo cannot run here (apk del luci-app-gatygo gatygo)"
fi

[ -x /usr/lib/gatygo/core/xray ] && NEED_KB=$NEED_KB_WITH_CORE
if [ "$FREE_KB" -ge "$NEED_KB" ]; then
    note "free space: $((FREE_KB / 1024)) MB on $MOUNT"
elif [ "$NEED_KB" = "$NEED_KB_WITH_CORE" ]; then
    warn "only $((FREE_KB / 1024)) MB free on $MOUNT: the geo files and an updated core need room"
else
    warn "only $((FREE_KB / 1024)) MB free on $MOUNT: the xray core alone takes 35 MB"
fi

if printf 'table inet gatygo_probe {\n chain c {\n  type filter hook prerouting priority mangle;\n  meta l4proto tcp tproxy ip to 127.0.0.1:12345 accept\n }\n}\n' | nft -c -f - >/dev/null 2>&1; then
    note "nftables takes the tproxy rules"
else
    warn "nftables does not take a tproxy rule: the LAN will not be proxied"
fi

if [ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq running >/dev/null 2>&1; then
    note "dnsmasq is running: gatygo will point it at xray's DNS"
else
    warn "dnsmasq is not running: gatygo resolves the LAN's names through it"
fi

if fetch_ok https://github.com; then
    note "github.com answers: the xray core can be downloaded"
else
    warn "github.com does not answer: gatygo cannot fetch the xray core"
fi

say ""
if /etc/init.d/gatygo running >/dev/null 2>&1; then
    say "Nothing else to do: the tunnel is up (gatygo status)."
else
    say "Next: LuCI -> Services -> gatygo -> paste the subscription URL -> Save & Apply."
    say "From the shell instead:"
    note "uci set gatygo.main.sub_url='<url>'; uci commit gatygo; /etc/init.d/gatygo start"
fi
