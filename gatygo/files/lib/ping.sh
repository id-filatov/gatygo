#!/bin/sh
# The response time of every country: the TCP connect time from the router straight to the
# profile's servers (the router's own traffic bypasses the tproxy rules), the fastest server
# counts. Not through the tunnel: xray runs one profile at a time. The addresses come from the
# subscription: they are checked here and only ever reach curl inside a URL.

. "${GATYGO_LIB:-/usr/lib/gatygo}/service.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/subscription.sh"

# jq: "ADDRESS PORT" of an outbound's server (vless/vmess vnext, trojan/shadowsocks servers, or
# the flat form), nothing for direct and block
_GATYGO_JQ_ENDPOINT='def endpoint: (.settings.vnext[0]? // .settings.servers[0]? // .settings // {})
    | select((.address | type) == "string" and (.port | type) != "null") | "\(.address) \(.port)";'

# gatygo_ping_endpoints SUB_JSON — print every server of the subscription once, "ADDRESS PORT"
gatygo_ping_endpoints() {
    jq -r "$_GATYGO_JQ_ENDPOINT [.[] | .outbounds[]? | endpoint] | unique | .[]" "$1" 2>/dev/null \
        | while read -r _gatygo_h _gatygo_p; do
            case $_gatygo_h in '' | *[!A-Za-z0-9._:-]* | -*) continue ;; esac
            case $_gatygo_p in '' | *[!0-9]*) continue ;; esac
            printf '%s %s\n' "$_gatygo_h" "$_gatygo_p"
        done
}

# _gatygo_ping_once ADDRESS PORT — print the TCP connect time in ms, nothing when the server did
# not answer in 3 s. OpenWrt's curl has neither telnet:// nor --connect-only: an https request it
# is, and only the connect time (less the name lookup) is read.
_gatygo_ping_once() {
    case $1 in *:*) _gatygo_u="https://[$1]:$2/" ;; *) _gatygo_u="https://$1:$2/" ;; esac
    curl -4 -k -s -o /dev/null -w '%{time_namelookup} %{time_connect}' --connect-timeout 3 --max-time 5 "$_gatygo_u" 2>/dev/null \
        | awk '$2 > 0 { ms = ($2 - $1) * 1000; printf "%d", (ms < 1) ? 1 : ms + 0.5 }'
}

# gatygo_ping_probe ADDRESS PORT — the better of two tries (the first one pays for a cold DNS
# cache); a server that did not answer is not tried again
gatygo_ping_probe() {
    _gatygo_a=$(_gatygo_ping_once "$1" "$2")
    [ -n "$_gatygo_a" ] || return 0
    _gatygo_b=$(_gatygo_ping_once "$1" "$2")
    [ -n "$_gatygo_b" ] && [ "$_gatygo_b" -lt "$_gatygo_a" ] && _gatygo_a=$_gatygo_b
    printf '%s' "$_gatygo_a"
}

# gatygo_ping_run SUB_JSON — probe every server, 8 at a time; print [{remarks, ms|null}] in the
# page's order, ms = the profile's fastest server
gatygo_ping_run() {
    _gatygo_w=$(mktemp -d) _gatygo_i=0 _gatygo_pids=''
    gatygo_ping_endpoints "$1" > "$_gatygo_w/list"
    while read -r _gatygo_h _gatygo_p; do
        _gatygo_i=$((_gatygo_i + 1))
        (printf '%s %s\t%s\n' "$_gatygo_h" "$_gatygo_p" "$(gatygo_ping_probe "$_gatygo_h" "$_gatygo_p")" > "$_gatygo_w/r$_gatygo_i") &
        _gatygo_pids="$_gatygo_pids $!"
        if [ $((_gatygo_i % 8)) -eq 0 ]; then
            # shellcheck disable=SC2086
            wait $_gatygo_pids
            _gatygo_pids=''
        fi
    done < "$_gatygo_w/list"
    # shellcheck disable=SC2086
    wait $_gatygo_pids
    cat "$_gatygo_w"/r* 2>/dev/null \
        | jq -Rn '[inputs | split("\t") | select((.[1] // "") != "") | {(.[0]): (.[1] | tonumber)}] | add // {}' > "$_gatygo_w/ms.json"
    jq -c --slurpfile ms "$_gatygo_w/ms.json" \
        "$_GATYGO_JQ_ENDPOINT $_GATYGO_JQ_PROFILES | map({remarks, ms: ([.outbounds[] | endpoint | \$ms[0][.] // empty] | min)})" "$1"
    rm -rf "$_gatygo_w"
}

# gatygo_ping_store PROFILES_JSON — keep the result in the run dir (tmpfs) and print it: the
# run that made it is over
gatygo_ping_store() {
    mkdir -p "$GATYGO_RUN"
    jq -nc --argjson profiles "$1" --argjson time "$(date +%s)" '{time: $time, profiles: $profiles}' > "$GATYGO_RUN/ping.json.tmp" \
        && mv "$GATYGO_RUN/ping.json.tmp" "$GATYGO_RUN/ping.json" \
        && jq -c '{time, measuring: false, profiles}' "$GATYGO_RUN/ping.json"
}

# gatygo_ping_kept MAX_AGE — print {time, measuring, profiles}: the kept result (time null when
# there is none) and whether a run is in progress. Exit 1 when a run is due: the result is
# missing or older than MAX_AGE seconds. Nothing to measure (no subscription) is never due.
gatygo_ping_kept() {
    _gatygo_m=false
    gatygo_locked ping && _gatygo_m=true
    if jq -c --argjson m "$_gatygo_m" '{time, measuring: $m, profiles}' "$GATYGO_RUN/ping.json" 2>/dev/null; then
        jq -e --argjson max "$1" --argjson now "$(date +%s)" '($now - .time) < $max' "$GATYGO_RUN/ping.json" >/dev/null 2>&1
    else
        printf '{"time":null,"measuring":%s,"profiles":[]}\n' "$_gatygo_m"
        [ ! -s "$GATYGO_STATE/subscription.json" ]
    fi
}
