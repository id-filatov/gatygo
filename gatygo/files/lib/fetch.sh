#!/bin/sh
# Download the subscription: mandatory headers, TLS verified, no redirects, 3 attempts.
#   gatygo_fetch URL UA HWID BODY_OUT HDR_OUT   -> prints HTTP status; exit 0 iff 200, 1 other status, 2 curl error
# curl's stderr carries the host name, so it is discarded; only the exit code and status are logged.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"

gatygo_fetch() {
    _gatygo_url=$1 _gatygo_ua=$2 _gatygo_hwid=$3 _gatygo_body=$4 _gatygo_hdr=$5
    _gatygo_code=$(curl -sS --max-time 30 --retry 3 --retry-delay 5 --retry-connrefused \
        --proto '=http,https' \
        -A "$_gatygo_ua" \
        -H "x-hwid: $_gatygo_hwid" \
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
