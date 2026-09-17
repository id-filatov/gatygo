#!/bin/sh
# Do the usual services open through the tunnel? The router's own traffic bypasses the tproxy
# rules, so the probes enter xray through its local SOCKS inbound (transform.jq, tag "check")
# and take the same route as the LAN. check.list: one "Name URL" per line.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"

# gatygo_check_probe PORT URL — print the time to the end of the TLS handshake in ms when the
# service gave any HTTP answer (a 403 or 405 to a bare HEAD still means it is reachable); print
# nothing when there was none within 5 s.
gatygo_check_probe() {
    curl -s -I -o /dev/null -w '%{http_code} %{time_pretransfer}' --connect-timeout 3 --max-time 5 \
        --socks5-hostname "127.0.0.1:$1" "$2" 2>/dev/null \
        | awk '$1 != "000" && $1 != "" { printf "%d", $2 * 1000 + 0.5 }'
}

# gatygo_check_run PORT — probe every listed service at once; print [{name, ms|null}] in list order
gatygo_check_run() {
    _gatygo_w=$(mktemp -d) _gatygo_i=0 _gatygo_pids=''
    while read -r _gatygo_name _gatygo_url; do
        [ -n "$_gatygo_url" ] || continue
        _gatygo_i=$((_gatygo_i + 1))
        (printf '%s\t%s\n' "$_gatygo_name" "$(gatygo_check_probe "$1" "$_gatygo_url")" > "$_gatygo_w/$_gatygo_i") &
        _gatygo_pids="$_gatygo_pids $!"
    done < "${GATYGO_CHECK_LIST:-${GATYGO_LIB:-/usr/lib/gatygo}/check.list}"
    # only the probes: a bare `wait` would also wait for anything else the caller runs
    # shellcheck disable=SC2086
    wait $_gatygo_pids
    _gatygo_n=1
    while [ "$_gatygo_n" -le "$_gatygo_i" ]; do cat "$_gatygo_w/$_gatygo_n"; _gatygo_n=$((_gatygo_n + 1)); done \
        | jq -Rnc '[inputs | split("\t") | {name: .[0], ms: (if (.[1] // "") == "" then null else (.[1] | tonumber) end)}]'
    rm -rf "$_gatygo_w"
}

# gatygo_check_store TUNNEL SERVICES_JSON — keep the result in the run dir (tmpfs) and print it.
# TUNNEL names what was measured: the profile and the xray process ("<profile>:<pid>").
gatygo_check_store() {
    mkdir -p "$GATYGO_RUN"
    jq -nc --arg tunnel "$1" --argjson services "$2" --argjson time "$(date +%s)" \
        '{available: true, tunnel: $tunnel, time: $time, services: $services}' > "$GATYGO_RUN/check.json.tmp" \
        && mv "$GATYGO_RUN/check.json.tmp" "$GATYGO_RUN/check.json" && cat "$GATYGO_RUN/check.json"
}

# gatygo_check_cached TUNNEL MAX_AGE — print the kept result when it is for TUNNEL and younger
# than MAX_AGE seconds; exit 1 otherwise
gatygo_check_cached() {
    [ -s "$GATYGO_RUN/check.json" ] || return 1
    jq -ce --arg tunnel "$1" --argjson max "$2" --argjson now "$(date +%s)" \
        'select(.tunnel == $tunnel and ($now - .time) < $max)' "$GATYGO_RUN/check.json" 2>/dev/null || return 1
}
