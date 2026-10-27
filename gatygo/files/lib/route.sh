#!/bin/sh
# Where a domain goes, as the running xray decides it: RoutingService.TestRoute of its API
# (transform.jq turns the service on, 127.0.0.1:10085). The call is in xray's
# app/router/command/command.proto, not in its documentation nor in `xray api`; it goes over
# HTTP/2 without TLS with curl, the protobuf written and read here (no grpc tools on the router).
# The user's rules only take traffic from the LAN's inbound (transform.jq): asked from an inbound
# tag no rule names, xray answers with the provider's rules alone.
# Requires config.sh; gatygo_route_available also service.sh.

GATYGO_API=${GATYGO_API:-127.0.0.1:10085}

# _gatygo_pb_byte N — write the byte N
_gatygo_pb_byte() { printf "\\$(printf '%03o' "$1")"; }

# _gatygo_pb_varint N
_gatygo_pb_varint() {
    _gatygo_v=$1
    while [ "$_gatygo_v" -ge 128 ]; do
        _gatygo_pb_byte $(((_gatygo_v & 127) | 128))
        _gatygo_v=$((_gatygo_v >> 7))
    done
    _gatygo_pb_byte "$_gatygo_v"
}

# _gatygo_pb_string FIELD STRING — a length-delimited field; the strings sent are ASCII
_gatygo_pb_string() {
    _gatygo_pb_byte $((($1 << 3) | 2))
    _gatygo_pb_varint "${#2}"
    printf '%s' "$2"
}

# gatygo_route_ask INBOUND DOMAIN [IPV4…] — print the tag of the outbound xray picks for a TCP
# connection to DOMAIN:443 that came in through INBOUND (and goes to IPV4 when given: a sniffed
# connection with routeOnly keeps its address). Exit 3: xray found no route, so the traffic
# would take the first outbound; exit 1: the call failed (no answer, no HTTP/2 in curl, any other
# gRPC status).
gatygo_route_ask() {
    _gatygo_in=$1 _gatygo_dom=$2
    shift 2
    _gatygo_w=$(mktemp -d)
    : > "$_gatygo_w/ips"
    for _gatygo_ip; do
        _gatygo_o=$(printf '%s\n' "$_gatygo_ip" | awk -F. 'NF == 4 && $0 ~ /^[0-9.]+$/ && $1 != "" && $2 != "" && $3 != "" && $4 != "" \
            && $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255 { print $1, $2, $3, $4 }')
        [ -n "$_gatygo_o" ] || { rm -rf "$_gatygo_w"; return 1; }
        # shellcheck disable=SC2086
        { _gatygo_pb_byte 34; _gatygo_pb_byte 4; for _gatygo_b in $_gatygo_o; do _gatygo_pb_byte "$_gatygo_b"; done; } >> "$_gatygo_w/ips"
    done
    # RoutingContext: 1 inbound tag, 2 network (2 = TCP), 4 target addresses, 6 target port, 7 target domain
    {
        _gatygo_pb_string 1 "$_gatygo_in"
        _gatygo_pb_byte 16; _gatygo_pb_byte 2
        cat "$_gatygo_w/ips"
        _gatygo_pb_byte 48; _gatygo_pb_varint 443
        _gatygo_pb_string 7 "$_gatygo_dom"
    } > "$_gatygo_w/ctx"
    # TestRouteRequest: 1 RoutingContext; the gRPC frame: no compression, 4 bytes of length
    { _gatygo_pb_byte 10; _gatygo_pb_varint "$(wc -c < "$_gatygo_w/ctx")"; cat "$_gatygo_w/ctx"; } > "$_gatygo_w/msg"
    _gatygo_n=$(wc -c < "$_gatygo_w/msg")
    {
        _gatygo_pb_byte 0
        _gatygo_pb_byte $(((_gatygo_n >> 24) & 255)); _gatygo_pb_byte $(((_gatygo_n >> 16) & 255))
        _gatygo_pb_byte $(((_gatygo_n >> 8) & 255)); _gatygo_pb_byte $((_gatygo_n & 255))
        cat "$_gatygo_w/msg"
    } > "$_gatygo_w/req"
    if ! curl -s --http2-prior-knowledge --max-time 5 -H 'content-type: application/grpc' -H 'te: trailers' \
            --data-binary @"$_gatygo_w/req" -D "$_gatygo_w/hdr" -o "$_gatygo_w/out" \
            "http://$GATYGO_API/xray.app.router.command.RoutingService/TestRoute" </dev/null 2>/dev/null; then
        rm -rf "$_gatygo_w"
        return 1
    fi
    # the status comes in the trailers, or in the headers of an answer without a body
    _gatygo_st=$(tr -d '\r' < "$_gatygo_w/hdr" | awk 'tolower($1) == "grpc-status:" { s = $2 } END { print s }')
    case $_gatygo_st in
        0) ;;
        2) rm -rf "$_gatygo_w"; return 3 ;;
        *) rm -rf "$_gatygo_w"; return 1 ;;
    esac
    # RoutingContext again: field 12 is the outbound tag
    _gatygo_tag=$(hexdump -v -e '/1 "%u\n"' "$_gatygo_w/out" | awk '
        function varint(   v, m) { v = 0; m = 1; while (i < n && b[i] >= 128) { v += (b[i] - 128) * m; m *= 128; i++ } v += b[i] * m; i++; return v }
        NR > 5 { b[n++] = $1 }
        END {
            i = 0
            while (i < n) {
                k = varint(); f = int(k / 8); w = k % 8
                if (w == 0) { varint(); continue }
                if (w == 1) { i += 8; continue }
                if (w == 5) { i += 4; continue }
                if (w != 2) break
                l = varint()
                if (f == 12) { s = ""; for (j = 0; j < l; j++) s = s sprintf("%c", b[i + j]); print s }
                i += l
            }
        }')
    rm -rf "$_gatygo_w"
    [ -n "$_gatygo_tag" ] || return 1
    printf '%s\n' "$_gatygo_tag"
}

# gatygo_route_to XRAY_JSON INBOUND DOMAIN [IPV4…] — print proxy, direct or block: the protocol of
# the outbound xray picks (freedom = direct, blackhole = block, anything else the tunnel); with no
# route, xray's own default: the first outbound. Exit 1 when the call failed.
gatygo_route_to() {
    _gatygo_cfg=$1
    shift
    _gatygo_tag=$(gatygo_route_ask "$@")
    case $? in
        0) _gatygo_p=$(jq -r --arg t "$_gatygo_tag" '[.outbounds[]? | select(.tag == $t) | .protocol] | first // empty' "$_gatygo_cfg") ;;
        3) _gatygo_p=$(jq -r '.outbounds[0].protocol // empty' "$_gatygo_cfg") ;;
        *) return 1 ;;
    esac
    case $_gatygo_p in
        '') return 1 ;;
        freedom) echo direct ;;
        blackhole) echo block ;;
        *) echo proxy ;;
    esac
}

# gatygo_route_ips DOMAIN — the IPv4 addresses of DOMAIN from the router's DNS, one per line
gatygo_route_ips() {
    nslookup "$1" 127.0.0.1 2>/dev/null </dev/null \
        | awk '/^Name:/ { seen = 1; next } seen && $1 == "Address:" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2 }'
}

# _gatygo_route_addresses XRAY_JSON DOMAIN — the addresses to ask with: the LAN's connections keep
# theirs when its inbound sniffs with routeOnly, so the provider's address rules see them
_gatygo_route_addresses() {
    jq -e '[.inbounds[]? | select(.tag == "tproxy") | .sniffing.routeOnly == true] | any' "$1" >/dev/null 2>&1 \
        && gatygo_route_ips "$2"
}

# gatygo_route_available — exit 0 iff xray runs a config that has the API inbound
gatygo_route_available() {
    gatygo_xray_running && jq -e '.inbounds[]? | select(.tag == "api")' "$GATYGO_STATE/xray.json" >/dev/null 2>&1
}

# gatygo_rules_status XRAY_JSON RULES_JSON — print [{domain, to, status}] for the rules, in their
# order. U: where the domain goes now, from the LAN's inbound; P: where it would go without the
# user's rules. status: provider_<U> when U is not the rule's direction (the provider's rule came
# first), nochange when P already was, works otherwise; null when xray did not answer.
gatygo_rules_status() {
    printf '%s' "$2" | jq -r '.[] | "\(.to) \(.domain)"' | while read -r _gatygo_to _gatygo_d; do
        _gatygo_ips=$(_gatygo_route_addresses "$1" "$_gatygo_d")
        _gatygo_s=null
        # shellcheck disable=SC2086
        if _gatygo_u=$(gatygo_route_to "$1" tproxy "$_gatygo_d" $_gatygo_ips) \
            && _gatygo_pv=$(gatygo_route_to "$1" gatygo-probe "$_gatygo_d" $_gatygo_ips); then
            if [ "$_gatygo_u" != "$_gatygo_to" ]; then _gatygo_s=provider_$_gatygo_u
            elif [ "$_gatygo_pv" = "$_gatygo_to" ]; then _gatygo_s=nochange
            else _gatygo_s=works
            fi
        fi
        printf '%s %s %s\n' "$_gatygo_to" "$_gatygo_d" "$_gatygo_s"
    done | jq -Rnc '[inputs | split(" ") | {domain: .[1], to: .[0], status: (if .[2] == "null" then null else .[2] end)}]'
}
