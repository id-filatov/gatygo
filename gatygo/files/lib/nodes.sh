#!/bin/sh
# Per-outbound view for the status page: which nodes the balancer currently uses and how much
# traffic each carried, from xray's API (statsquery, bi) merged with the installed config.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"

GATYGO_API=${GATYGO_API:-127.0.0.1:10085}

# gatygo_nodes XRAY_JSON — print {"api": bool, "balancer": tag|null, "nodes": [{tag, address, in_use, up, down}]}
# Outbounds keep the config order; dns-out and block are skipped. Without the API (xray not
# running) the list still comes from the config with zero counters and nothing in use.
gatygo_nodes() {
    _gatygo_bal=$(jq -r '.routing.balancers[0].tag // empty' "$1" 2>/dev/null)
    _gatygo_stats='{"stat":[]}' _gatygo_sel='[]' _gatygo_api=false
    if _gatygo_s=$("$GATYGO_XRAY" api statsquery --server="$GATYGO_API" -timeout 1 -json -pattern 'outbound>>>' 2>/dev/null); then
        _gatygo_stats=$_gatygo_s _gatygo_api=true
        if [ -n "$_gatygo_bal" ]; then
            _gatygo_sel=$("$GATYGO_XRAY" api bi --server="$GATYGO_API" -timeout 1 -json "$_gatygo_bal" 2>/dev/null \
                | jq -c '.balancer.principleTarget.tag // []' 2>/dev/null)
            [ -n "$_gatygo_sel" ] || _gatygo_sel='[]'
        fi
    fi
    jq -c --argjson api "$_gatygo_api" --arg bal "$_gatygo_bal" --argjson stats "$_gatygo_stats" --argjson sel "$_gatygo_sel" '
        ([$stats.stat[]? | select(.name | startswith("outbound>>>")) | (.name | split(">>>")) as $p
            | {tag: $p[1], dir: $p[3], value: ((.value // 0) | tonumber)}]
         | group_by(.tag)
         | map({key: .[0].tag, value: {up: ([.[] | select(.dir == "uplink") | .value] | add // 0),
                                        down: ([.[] | select(.dir == "downlink") | .value] | add // 0)}})
         | from_entries) as $traffic
        | {api: $api,
           balancer: (if $bal == "" then null else $bal end),
           nodes: [.outbounds[] | select(.protocol != "dns" and .protocol != "blackhole")
                   | .tag as $t
                   | {tag: $t, address: (.settings.vnext[0].address // ""),
                      in_use: ($sel | any(. == $t)),
                      up: ($traffic[$t].up // 0), down: ($traffic[$t].down // 0)}]}' "$1"
}
