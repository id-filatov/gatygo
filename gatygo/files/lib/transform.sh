#!/bin/sh
# gatygo_transform IN OUT TPROXY_PORT DNS_PORT MARK LOGLEVEL ERROR_LOG
# Run transform.jq on the selected profile config. Ports and mark are decimal unsigned
# integers (convert UCI "0xff" with $(( 0xff )) before calling). On any failure exit 1
# and leave OUT untouched.

. "${GATYGO_LIB:-/usr/lib/gatygo}/common.sh"

_gatygo_is_uint() {
    case $1 in '' | *[!0-9]*) return 1 ;; esac
}

gatygo_transform() {
    _gatygo_in=$1 _gatygo_out=$2 _gatygo_tp=$3 _gatygo_dp=$4 _gatygo_mark=$5 _gatygo_lvl=$6 _gatygo_elog=$7
    if ! _gatygo_is_uint "$_gatygo_tp" || ! _gatygo_is_uint "$_gatygo_dp" || ! _gatygo_is_uint "$_gatygo_mark"; then
        gatygo_log error "transform: tproxy port, dns port and mark must be unsigned integers"
        return 1
    fi
    _gatygo_tmp="$_gatygo_out.tmp.$$"
    if jq --argjson tproxy_port "$_gatygo_tp" --argjson dns_port "$_gatygo_dp" --argjson mark "$_gatygo_mark" \
          --arg loglevel "$_gatygo_lvl" --arg error_log "$_gatygo_elog" \
          -f "${GATYGO_LIB:-/usr/lib/gatygo}/transform.jq" "$_gatygo_in" > "$_gatygo_tmp" 2>/dev/null; then
        mv "$_gatygo_tmp" "$_gatygo_out"
    else
        rm -f "$_gatygo_tmp"
        gatygo_log error "transform: jq failed on the selected config"
        return 1
    fi
}
