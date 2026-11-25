#!/bin/sh
# Download the subscription: mandatory headers (x-hwid only when a hwid is given), TLS verified,
# no redirects, 3 retries (RETRIES when given). A server that does not answer the connection is
# given up on in 10 s a try: the countries on the page stay locked while an update runs.
#   gatygo_fetch URL UA HWID BODY_OUT HDR_OUT [RETRIES]   -> prints HTTP status; exit 0 iff 200, 1 other status, 2 curl error
# curl's stderr carries the host name, so it is discarded; only the exit code and status are logged.
# Below: the ways of asking for it (which User-Agent, which address) and the one that worked.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"

gatygo_fetch() {
    _gatygo_url=$1 _gatygo_ua=$2 _gatygo_hwid=$3 _gatygo_body=$4 _gatygo_hdr=$5 _gatygo_retries=${6:-3}
    set --
    [ -z "$_gatygo_hwid" ] || set -- -H "x-hwid: $_gatygo_hwid"
    _gatygo_code=$(curl -sS --connect-timeout 10 --max-time 30 --retry "$_gatygo_retries" --retry-delay 5 --retry-connrefused \
        --proto '=http,https' \
        -A "$_gatygo_ua" "$@" \
        -H "x-device-os: OpenWrt" \
        -H "x-ver-os: $(gatygo_os_version)" \
        -H "x-device-model: $(gatygo_device_model)" \
        -H "Accept: */*" \
        -H "Accept-Encoding: identity" \
        -D "$_gatygo_hdr" -o "$_gatygo_body" -w '%{http_code}' "$_gatygo_url" 2>/dev/null)
    _gatygo_rc=$?
    if [ "$_gatygo_rc" -ne 0 ]; then
        gatygo_log error "fetch: curl failed (exit $_gatygo_rc)"
        return 2
    fi
    printf '%s\n' "$_gatygo_code"
    if [ "$_gatygo_code" != 200 ]; then
        gatygo_log error "fetch: HTTP $_gatygo_code"
        return 1
    fi
}

# The ways of asking for the subscription, in the order they are tried. A provider's server picks
# the format of its answer by the request, and gatygo needs Xray JSON:
#   mixed       an app name servers commonly answer with Xray JSON and server descriptions, with
#               gatygo's own name in it, so the provider sees which client asks
#   mixed-json  the same name on <link>/json, where many servers give Xray JSON to any name
#   gatygo      gatygo's own name, for a server with a rule for it
#   happ, v2rayng, v2rayn, streisand
#               names of apps that take Xray JSON, for servers that match them exactly
GATYGO_WAYS='mixed mixed-json gatygo happ v2rayng v2rayn streisand'

# gatygo_way_list [FIRST] — the ways, one per line; FIRST (a known way) first, not twice
gatygo_way_list() {
    _gatygo_wf=''
    for _gatygo_wk in $GATYGO_WAYS; do [ "$_gatygo_wk" = "${1:-}" ] && _gatygo_wf=$1; done
    [ -z "$_gatygo_wf" ] || printf '%s\n' "$_gatygo_wf"
    for _gatygo_wk in $GATYGO_WAYS; do [ "$_gatygo_wk" = "$_gatygo_wf" ] || printf '%s\n' "$_gatygo_wk"; done
}

# gatygo_way_ua WAY — the User-Agent of WAY; exit 1 for an unknown one
gatygo_way_ua() {
    case $1 in
        mixed | mixed-json) printf '%s\n' "Happ/3.0.0 (gatygo/$GATYGO_VERSION)" ;;
        gatygo) printf '%s\n' "gatygo/$GATYGO_VERSION" ;;
        happ) printf '%s\n' "Happ/3.0.0" ;;
        v2rayng) printf '%s\n' "v2rayNG/1.10.5" ;;
        v2rayn) printf '%s\n' "v2rayN/7.13.2" ;;
        streisand) printf '%s\n' "Streisand/1.6.40" ;;
        *) return 1 ;;
    esac
}

# gatygo_way_url WAY URL — the address WAY asks: URL as is, or for mixed-json URL with /json at
# the end of its path (before a query string or a fragment, without a double slash)
gatygo_way_url() {
    [ "$1" = mixed-json ] || { printf '%s\n' "$2"; return 0; }
    _gatygo_wb=${2%%[?#]*}
    printf '%s/json%s\n' "${_gatygo_wb%/}" "${2#"$_gatygo_wb"}"
}

# _gatygo_way_for URL — the fingerprint sub-way.env keeps instead of the link (a secret)
_gatygo_way_for() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# gatygo_way_saved URL — the way that worked last time for the link URL, or nothing
gatygo_way_saved() {
    _gatygo_wfile="$GATYGO_STATE/sub-way.env"
    [ -f "$_gatygo_wfile" ] || return 0
    [ "$(_gatygo_env_get "$_gatygo_wfile" GATYGO_WAY_FOR)" = "$(_gatygo_way_for "$1")" ] || return 0
    _gatygo_env_get "$_gatygo_wfile" GATYGO_WAY
}

# gatygo_way_save WAY URL — keep WAY for the link URL (0600, atomic); a file that already says so
# is left alone: the router's flash is not written on every update
gatygo_way_save() {
    _gatygo_wfile="$GATYGO_STATE/sub-way.env"
    _gatygo_wnew=$(printf 'GATYGO_WAY=%s\nGATYGO_WAY_FOR=%s' "$(gatygo_shquote "$1")" "$(gatygo_shquote "$(_gatygo_way_for "$2")")")
    [ "$(cat "$_gatygo_wfile" 2>/dev/null)" = "$_gatygo_wnew" ] && return 0
    printf '%s\n' "$_gatygo_wnew" > "$_gatygo_wfile.tmp" && chmod 600 "$_gatygo_wfile.tmp" \
        && mv "$_gatygo_wfile.tmp" "$_gatygo_wfile"
}
