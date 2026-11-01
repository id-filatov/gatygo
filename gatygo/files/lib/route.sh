#!/bin/sh
# Where a domain goes, as the running xray decides it: RoutingService.TestRoute of its API
# (transform.jq turns the service on, 127.0.0.1:10085). The call is in xray's
# app/router/command/command.proto, not in its documentation nor in `xray api`; it goes over
# HTTP/2 without TLS with curl, the protobuf written and read here (no grpc tools on the router).
# The user's rules only take traffic from the LAN's inbound (transform.jq): asked from an inbound
# tag no rule names, xray answers with the provider's rules alone.
# The requests are built by the shell itself (printf escapes, no process per byte) and one curl
# sends all of them over one connection: the cost of the statuses hardly grows with the rules.
# An address rule is asked with an address alone: those are the connections it takes (a site's
# name, when xray sees it, goes by the domain rules and the provider's catch-all first).
# Requires config.sh.

. "${GATYGO_LIB:-/usr/lib/gatygo}/addr.sh"

GATYGO_API=${GATYGO_API:-127.0.0.1:10085}

# _gatygo_pb_byte N — append the byte N to the message being built (_gatygo_b, _gatygo_c bytes)
_gatygo_pb_byte() {
    _gatygo_b="$_gatygo_b\\$((($1 >> 6) & 7))$((($1 >> 3) & 7))$(($1 & 7))"
    _gatygo_c=$((_gatygo_c + 1))
}

# _gatygo_pb_varint N
_gatygo_pb_varint() {
    _gatygo_v=$1
    while [ "$_gatygo_v" -ge 128 ]; do
        _gatygo_pb_byte $(((_gatygo_v & 127) | 128))
        _gatygo_v=$((_gatygo_v >> 7))
    done
    _gatygo_pb_byte "$_gatygo_v"
}

# _gatygo_pb_string FIELD STRING — a length-delimited field. STRING goes into a printf format as it
# is: callers pass a checked domain or one of our inbound tags (no '%', no '\').
_gatygo_pb_string() {
    _gatygo_pb_byte $((($1 << 3) | 2))
    _gatygo_pb_varint "${#2}"
    _gatygo_b="$_gatygo_b$2"
    _gatygo_c=$((_gatygo_c + ${#2}))
}

# _gatygo_pb_ipv4 ADDRESS — append field 4 (a target address) for a dotted quad; exit 1 otherwise
_gatygo_pb_ipv4() {
    case $1 in *[!0-9.]* | .* | *. | *..*) return 1 ;; esac
    _gatygo_ifs=$IFS
    IFS=.
    # shellcheck disable=SC2086
    set -- $1
    IFS=$_gatygo_ifs
    [ $# -eq 4 ] || return 1
    _gatygo_pb_byte 34
    _gatygo_pb_byte 4
    for _gatygo_o; do
        [ "${#_gatygo_o}" -le 3 ] || return 1
        # no leading zeros: $((010)) is octal
        _gatygo_o=${_gatygo_o#"${_gatygo_o%%[!0]*}"}
        [ "${_gatygo_o:-0}" -le 255 ] || return 1
        _gatygo_pb_byte "${_gatygo_o:-0}"
    done
}

# _gatygo_route_request FILE INBOUND DOMAIN [IPV4…] — write the gRPC request for a TCP connection
# to DOMAIN:443 (none when DOMAIN is "-") that came in through INBOUND, going to IPV4 when given
_gatygo_route_request() {
    _gatygo_rf=$1 _gatygo_rin=$2 _gatygo_rdom=$3
    shift 3
    case $_gatygo_rin in '' | *[!a-z0-9-]*) return 1 ;; esac
    case $_gatygo_rdom in *[!a-z0-9.-]*) return 1 ;; esac
    # RoutingContext: 1 inbound tag, 2 network (2 = TCP), 4 target addresses, 6 target port, 7 target domain
    _gatygo_b='' _gatygo_c=0
    _gatygo_pb_string 1 "$_gatygo_rin"
    _gatygo_pb_byte 16
    _gatygo_pb_byte 2
    for _gatygo_ip; do _gatygo_pb_ipv4 "$_gatygo_ip" || return 1; done
    _gatygo_pb_byte 48
    _gatygo_pb_varint 443
    [ "$_gatygo_rdom" = - ] || [ -z "$_gatygo_rdom" ] || _gatygo_pb_string 7 "$_gatygo_rdom"
    _gatygo_ctx=$_gatygo_b _gatygo_n=$_gatygo_c
    # TestRouteRequest: 1 RoutingContext
    _gatygo_b='' _gatygo_c=0
    _gatygo_pb_byte 10
    _gatygo_pb_varint "$_gatygo_n"
    _gatygo_msg="$_gatygo_b$_gatygo_ctx" _gatygo_n=$((_gatygo_n + _gatygo_c))
    # the gRPC frame: no compression, 4 bytes of length
    _gatygo_b='' _gatygo_c=0
    _gatygo_pb_byte 0
    _gatygo_pb_byte $(((_gatygo_n >> 24) & 255))
    _gatygo_pb_byte $(((_gatygo_n >> 16) & 255))
    _gatygo_pb_byte $(((_gatygo_n >> 8) & 255))
    _gatygo_pb_byte $((_gatygo_n & 255))
    # shellcheck disable=SC2059
    printf "$_gatygo_b$_gatygo_msg" > "$_gatygo_rf"
}

# _gatygo_route_send DIR COUNT — send DIR/1.req … DIR/COUNT.req (a missing one is skipped) with one
# curl, over one HTTP/2 connection, and write DIR/answers, a line per request: "<n> <tag>" for the
# outbound xray picked, "<n> -" when it found no route (the traffic takes the first outbound),
# "<n> !" when the call failed (no answer, no HTTP/2 in curl, any other gRPC status)
_gatygo_route_send() {
    _gatygo_d=$1 _gatygo_k=$2 _gatygo_i=1
    set --
    while [ "$_gatygo_i" -le "$_gatygo_k" ]; do
        : > "$_gatygo_d/$_gatygo_i.hdr"
        : > "$_gatygo_d/$_gatygo_i.out"
        if [ -f "$_gatygo_d/$_gatygo_i.req" ]; then
            [ $# -eq 0 ] || set -- "$@" --next
            set -- "$@" -s --http2-prior-knowledge --max-time 5 -H 'content-type: application/grpc' -H 'te: trailers' \
                --data-binary "@$_gatygo_d/$_gatygo_i.req" -D "$_gatygo_d/$_gatygo_i.hdr" -o "$_gatygo_d/$_gatygo_i.out" \
                "http://$GATYGO_API/xray.app.router.command.RoutingService/TestRoute"
        fi
        _gatygo_i=$((_gatygo_i + 1))
    done
    [ $# -eq 0 ] || curl "$@" </dev/null >/dev/null 2>&1
    # the gRPC status of every call: in the trailers, or in the headers of an answer without a body
    _gatygo_i=1
    set --
    while [ "$_gatygo_i" -le "$_gatygo_k" ]; do set -- "$@" "$_gatygo_d/$_gatygo_i.hdr"; _gatygo_i=$((_gatygo_i + 1)); done
    [ $# -eq 0 ] || awk -v k="$_gatygo_k" '
        tolower($1) == "grpc-status:" { f = FILENAME; sub(/.*\//, "", f); sub(/\.hdr$/, "", f); s = $2; sub(/\r$/, "", s); st[f] = s }
        END { for (i = 1; i <= k; i++) print i, (i in st) ? st[i] : "" }' "$@" > "$_gatygo_d/status"
    : >> "$_gatygo_d/status"
    # the answers of the calls that succeeded, in order, one gRPC frame each: RoutingContext again,
    # field 12 is the outbound tag
    set --
    while read -r _gatygo_i _gatygo_s; do [ "$_gatygo_s" != 0 ] || set -- "$@" "$_gatygo_d/$_gatygo_i.out"; done < "$_gatygo_d/status"
    [ $# -gt 0 ] || set -- /dev/null
    hexdump -v -e '/1 "%u\n"' "$@" | awk -v sf="$_gatygo_d/status" '
        function varint(   v, m) { v = 0; m = 1; while (i < n && b[i] >= 128) { v += (b[i] - 128) * m; m *= 128; i++ } v += b[i] * m; i++; return v }
        { b[n++] = $1 }
        END {
            i = 0
            while (i + 5 <= n) {
                e = i + 5 + b[i + 1] * 16777216 + b[i + 2] * 65536 + b[i + 3] * 256 + b[i + 4]
                i += 5; tag = ""
                while (i < e) {
                    k = varint(); f = int(k / 8); w = k % 8
                    if (w == 0) { varint(); continue }
                    if (w == 1) { i += 8; continue }
                    if (w == 5) { i += 4; continue }
                    if (w != 2) break
                    l = varint()
                    if (f == 12) { tag = ""; for (j = 0; j < l; j++) tag = tag sprintf("%c", b[i + j]) }
                    i += l
                }
                i = e; tags[++t] = tag
            }
            while ((getline line < sf) > 0) {
                split(line, a, " ")
                if (a[2] == "0") { m++; print a[1], (tags[m] != "") ? tags[m] : "!" }
                else if (a[2] == "2") print a[1], "-"
                else print a[1], "!"
            }
        }' > "$_gatygo_d/answers"
}

# _gatygo_route_conf XRAY_JSON DIR — write DIR/conf (the protocol of every outbound, "-" for the
# first one: xray's default) and print what the LAN's connections carry for the rules to see:
# domain; both (a domain and its address: routeOnly); address (the inbound does not sniff the
# domain of an HTTPS connection, so no domain rule can take it)
_gatygo_route_conf() {
    jq -r '([.inbounds[]? | select(.tag == "tproxy") | .sniffing][0] // {}) as $s
        | ($s.enabled == true and (($s.destOverride // []) | any(. == "fakedns" or (. == "tls" and $s.metadataOnly != true)))) as $dom
        | (if $dom then (if $s.routeOnly == true then "both" else "domain" end) else "address" end),
          "- \(.outbounds[0].protocol // "")",
          (.outbounds[]? | "\(.tag) \(.protocol)")' "$1" > "$2/conf" 2>/dev/null || return 1
    head -n 1 "$2/conf"
}

# _gatygo_route_dirs DIR — DIR/answers as directions in DIR/dirs: "<n> proxy|direct|block|!"
# (freedom = direct, blackhole = block, anything else the tunnel)
_gatygo_route_dirs() {
    awk 'FILENAME == ARGV[1] { if (FNR > 1) p[$1] = $2; next }
        { x = ($2 == "!") ? "" : p[$2]
          print $1, (x == "") ? "!" : (x == "freedom") ? "direct" : (x == "blackhole") ? "block" : "proxy" }' \
        "$1/conf" "$1/answers" > "$1/dirs"
}

# gatygo_route_ask INBOUND DOMAIN [IPV4…] — print the tag of the outbound xray picks for a TCP
# connection to DOMAIN:443 that came in through INBOUND (and goes to IPV4 when given). Exit 3: xray
# found no route, so the traffic would take the first outbound; exit 1: the call failed.
gatygo_route_ask() {
    _gatygo_w=$(mktemp -d)
    if ! _gatygo_route_request "$_gatygo_w/1.req" "$@"; then rm -rf "$_gatygo_w"; return 1; fi
    _gatygo_route_send "$_gatygo_w" 1
    read -r _gatygo_i _gatygo_tag < "$_gatygo_w/answers"
    rm -rf "$_gatygo_w"
    case $_gatygo_tag in
        '' | '!') return 1 ;;
        -) return 3 ;;
    esac
    printf '%s\n' "$_gatygo_tag"
}

# _gatygo_route_one INBOUND DOMAIN [IPV4…] — the direction of one connection (as gatygo_route_to);
# the work dir is _gatygo_w, its conf already written
_gatygo_route_one() {
    _gatygo_route_request "$_gatygo_w/1.req" "$@" || return 1
    _gatygo_route_send "$_gatygo_w" 1
    _gatygo_route_dirs "$_gatygo_w"
    read -r _gatygo_i _gatygo_dir < "$_gatygo_w/dirs"
    case $_gatygo_dir in proxy | direct | block) printf '%s\n' "$_gatygo_dir" ;; *) return 1 ;; esac
}

# gatygo_route_to XRAY_JSON INBOUND DOMAIN [IPV4…] — print proxy, direct or block: the protocol of
# the outbound xray picks; with no route, xray's own default, the first outbound. Exit 1 when the
# call failed.
gatygo_route_to() {
    _gatygo_w=$(mktemp -d)
    _gatygo_route_conf "$1" "$_gatygo_w" >/dev/null && shift && _gatygo_route_one "$@"
    _gatygo_rc=$?
    rm -rf "$_gatygo_w"
    return "$_gatygo_rc"
}

# gatygo_route_addr_why ADDR — why xray never sees ADDR's traffic, if it does not (ADDR canonical):
# local (always direct, IPv6 too: the IPv6 block leaves the local ranges alone), ipv6_blocked
# (IPv6 off in the settings), ipv6_bypass (IPv6 goes around the VPN); exit 1 when xray sees it
gatygo_route_addr_why() {
    if gatygo_addr_local "$1"; then echo local
    elif [ "$(gatygo_addr_family "$1")" = 6 ]; then
        if [ "${GATYGO_IPV6_BLOCK:-1}" = 1 ]; then echo ipv6_blocked; else echo ipv6_bypass; fi
    else return 1
    fi
}

# gatygo_route_narrower ADDR [RULE...] — the IPv4 rules among RULE with a longer mask than ADDR's:
# an address of ADDR they hold goes by them, not by ADDR's rule
gatygo_route_narrower() {
    _gatygo_nm=32
    case $1 in */*) _gatygo_nm=${1#*/} ;; esac
    shift
    for _gatygo_x; do
        _gatygo_xm=32
        case $_gatygo_x in *:*) continue ;; */*) _gatygo_xm=${_gatygo_x#*/} ;; esac
        [ "$_gatygo_xm" -le "$_gatygo_nm" ] || printf '%s\n' "$_gatygo_x"
    done
}

# gatygo_route_where XRAY_JSON DOMAIN|IPV4 [NARROWER...] — where a LAN device's connection to DOMAIN
# goes now, with what the LAN's inbound lets the rules see (its domain, its address, or both). An
# IPv4 address or subnet (canonical, not local) is asked at the address its status would be: the
# first one outside the local network and the user's NARROWER rules (or outside the local network
# alone when they hold all of it).
gatygo_route_where() {
    _gatygo_w=$(mktemp -d)
    _gatygo_mode=$(_gatygo_route_conf "$1" "$_gatygo_w")
    _gatygo_rc=1
    if [ -n "$_gatygo_mode" ]; then
        _gatygo_ips='' _gatygo_dm=$2
        _gatygo_wt=$2
        shift 2
        case $_gatygo_wt in
            *[!0-9./]*)
                [ "$_gatygo_mode" = domain ] || _gatygo_ips=$(gatygo_route_ips "$_gatygo_wt")
                [ "$_gatygo_mode" != address ] || _gatygo_dm=- ;;
            *)
                _gatygo_dm=-
                _gatygo_ips=$(gatygo_addr_probe "$_gatygo_wt" "$@") || _gatygo_ips=$(gatygo_addr_probe "$_gatygo_wt") ;;
        esac
        # shellcheck disable=SC2086
        _gatygo_route_one tproxy "$_gatygo_dm" $_gatygo_ips
        _gatygo_rc=$?
    fi
    rm -rf "$_gatygo_w"
    return "$_gatygo_rc"
}

# gatygo_route_ips DOMAIN — the IPv4 addresses of DOMAIN from the router's DNS, one per line
gatygo_route_ips() {
    nslookup "$1" 127.0.0.1 2>/dev/null </dev/null \
        | awk '/^Name:/ { seen = 1; next } seen && $1 == "Address:" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2 }'
}

# gatygo_route_api XRAY_JSON — exit 0 iff the config has the API inbound and the API answers
# (asked from its own inbound: that rule comes second in every config, no DNS behind it)
gatygo_route_api() {
    jq -e '.inbounds[]? | select(.tag == "api")' "$1" >/dev/null 2>&1 && gatygo_route_ask api example.com >/dev/null
}

# gatygo_rules_status XRAY_JSON RULES_JSON — print [{domain or ip, to, status}] for the rules, in
# their order. U: where the connection goes now, from the LAN's inbound; P: where it would go
# without the user's rules. status: provider_<U> when U is not the rule's direction (the provider's
# rule came first), nochange when P already was, works otherwise; null when xray did not answer.
# A domain rule is asked with its domain. When the LAN's connections carry no domain (no TLS
# sniffing), no domain rule can take them: asked with the address alone, nochange, or
# provider_<U> when the provider's rules alone send the address there too (a user's address rule
# may be what took it). An address rule is asked at one address of it: the first one outside the
# local network and the user's narrower address rules (none: nochange, the narrower ones decide);
# local, ipv6_blocked and ipv6_bypass when xray never sees its traffic (a direct rule there:
# nochange, it goes direct anyway; ipv6_blocked whatever the direction).
gatygo_rules_status() {
    _gatygo_w=$(mktemp -d)
    _gatygo_mode=$(_gatygo_route_conf "$1" "$_gatygo_w")
    printf '%s' "$2" | jq -r '.[] | if has("ip") then "\(.to) ip \(.ip)" else "\(.to) domain \(.domain)" end' > "$_gatygo_w/rules"
    # the IPv4 address rules, for the narrower ones of each
    _gatygo_v4=''
    while read -r _gatygo_to _gatygo_kd _gatygo_d; do
        [ "$_gatygo_kd" = ip ] && _gatygo_v4="$_gatygo_v4 $_gatygo_d"
    done < "$_gatygo_w/rules"
    _gatygo_k=0
    : > "$_gatygo_w/pre"
    while read -r _gatygo_to _gatygo_kd _gatygo_d; do
        _gatygo_k=$((_gatygo_k + 1))
        if [ "$_gatygo_kd" = ip ]; then
            # a status known without asking, or the address to ask at
            _gatygo_pre=-
            case $(gatygo_route_addr_why "$_gatygo_d") in
                local) [ "$_gatygo_to" = proxy ] && _gatygo_pre=local || _gatygo_pre=nochange ;;
                ipv6_blocked) _gatygo_pre=ipv6_blocked ;;
                ipv6_bypass) [ "$_gatygo_to" = proxy ] && _gatygo_pre=ipv6_bypass || _gatygo_pre=nochange ;;
                *)
                    # shellcheck disable=SC2046,SC2086
                    _gatygo_ips=$(gatygo_addr_probe "$_gatygo_d" $(gatygo_route_narrower "$_gatygo_d" $_gatygo_v4)) || _gatygo_pre=nochange ;;
            esac
            echo "$_gatygo_k $_gatygo_pre" >> "$_gatygo_w/pre"
            [ "$_gatygo_pre" = - ] || continue
            _gatygo_dm=-
        else
            _gatygo_ips='' _gatygo_dm=$_gatygo_d
            [ "$_gatygo_mode" = domain ] || _gatygo_ips=$(gatygo_route_ips "$_gatygo_d")
            [ "$_gatygo_mode" != address ] || _gatygo_dm=-
        fi
        # shellcheck disable=SC2086
        _gatygo_route_request "$_gatygo_w/$((2 * _gatygo_k - 1)).req" tproxy "$_gatygo_dm" $_gatygo_ips
        # shellcheck disable=SC2086
        _gatygo_route_request "$_gatygo_w/$((2 * _gatygo_k)).req" gatygo-probe "$_gatygo_dm" $_gatygo_ips
    done < "$_gatygo_w/rules"
    _gatygo_route_send "$_gatygo_w" $((2 * _gatygo_k))
    _gatygo_route_dirs "$_gatygo_w"
    awk -v mode="$_gatygo_mode" 'FILENAME == ARGV[1] { d[$1] = $2; next }
        FILENAME == ARGV[2] { pre[$1] = $2; next }
        { u = d[2 * FNR - 1]; p = d[2 * FNR]; s = "null"
          uok = (u != "" && u != "!"); pok = (p != "" && p != "!")
          if (pre[FNR] != "" && pre[FNR] != "-") s = pre[FNR]
          else if (!uok) s = "null"
          else if ($2 == "domain" && mode == "address") {
              if (u == $1) s = "nochange"
              else if (pok) s = (p == u) ? "provider_" u : "nochange"
          }
          else if (u != $1) s = "provider_" u
          else if (pok) s = (p == $1) ? "nochange" : "works"
          print $1, $2, $3, s }' "$_gatygo_w/dirs" "$_gatygo_w/pre" "$_gatygo_w/rules" \
        | jq -Rnc '[inputs | split(" ") | {(.[1]): .[2], to: .[0], status: (if .[3] == "null" then null else .[3] end)}]'
    rm -rf "$_gatygo_w"
}
