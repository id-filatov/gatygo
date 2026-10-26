#!/bin/sh
# A relay that moved to another address. xray looks a relay's name up only when it opens a
# connection, and its gRPC transport keeps one connection for as long as the old machine answers:
# a changed DNS record goes unseen, and the config (names only) stays the same, so an update would
# not restart xray either. The run dir keeps every address the relay names had while the router
# runs; an update restarts xray when xray still holds one that its name no longer has. The
# addresses xray holds alone would not do: it also connects straight to sites, often on a
# relay's port.

. "${GATYGO_LIB:-/usr/lib/gatygo}/service.sh"

# gatygo_relay_endpoints XRAY_JSON — "HOST PORT" of every relay given by name (vnext, servers or
# flat settings), once; IP literals and odd names or ports are left out
gatygo_relay_endpoints() {
    jq -r '[.outbounds[]? | (.settings.vnext // .settings.servers // [.settings // {}])[]?
            | select((.address | type) == "string" and (.port | type) != "null") | "\(.address) \(.port)"]
           | unique | .[]' "$1" 2>/dev/null \
        | while read -r _gatygo_h _gatygo_p; do
            case $_gatygo_h in '' | *[!A-Za-z0-9.-]* | -*) continue ;; esac
            case $_gatygo_h in *[!0-9.]*) ;; *) continue ;; esac
            case $_gatygo_p in '' | *[!0-9]*) continue ;; esac
            printf '%s %s\n' "$_gatygo_h" "$_gatygo_p"
        done
}

# gatygo_resolve HOST — the addresses the system resolver (dnsmasq, which xray asks too) has for
# HOST, one per line; nothing without an answer
gatygo_resolve() {
    nslookup "$1" 2>/dev/null | awk '/^Name:/ { n = 1; next } n && /^Address/ && $NF ~ /^[0-9A-Fa-f.:]+$/ { print $NF }'
}

# gatygo_xray_peers PID — "ADDRESS PORT" of every established TCP connection of process PID
gatygo_xray_peers() {
    netstat -tnpW 2>/dev/null | awk -v pid="$1" '$6 == "ESTABLISHED" && index($7, pid "/") == 1 {
        i = match($5, /:[0-9]+$/); a = substr($5, 1, i - 1); sub(/^::ffff:/, "", a); print a, substr($5, i + 1) }'
}

# _gatygo_relay_now XRAY_JSON — "HOST PORT ADDRESS" for every named relay and address it has now
_gatygo_relay_now() {
    gatygo_relay_endpoints "$1" | while read -r _gatygo_h _gatygo_p; do
        gatygo_resolve "$_gatygo_h" | awk -v h="$_gatygo_h" -v p="$_gatygo_p" '{ print h, p, $0 }'
    done
}

# _gatygo_relay_add FILE — add FILE's lines to the addresses kept in the run dir
_gatygo_relay_add() {
    mkdir -p "$GATYGO_RUN"
    { cat "$GATYGO_RUN/relay-addresses" 2>/dev/null; cat "$1"; } | sort -u > "$GATYGO_RUN/relay-addresses.$$" \
        && mv "$GATYGO_RUN/relay-addresses.$$" "$GATYGO_RUN/relay-addresses"
}

# gatygo_relay_note XRAY_JSON — keep the addresses the relay names have now. The service calls it
# as xray starts: these are the ones xray is about to connect to.
gatygo_relay_note() {
    _gatygo_rt=$(mktemp)
    _gatygo_relay_now "$1" > "$_gatygo_rt"
    _gatygo_relay_add "$_gatygo_rt"
    rm -f "$_gatygo_rt"
}

# gatygo_relay_moved XRAY_JSON — exit 0 iff xray holds a connection to an address that a relay's
# name had (on the relay's port) and no longer has; logs each. A name without an answer now is
# left alone. The addresses the names have now are kept too.
gatygo_relay_moved() {
    _gatygo_pid=$(gatygo_xray_pid)
    [ -n "$_gatygo_pid" ] || return 1
    _gatygo_rt=$(mktemp -d)
    _gatygo_relay_now "$1" > "$_gatygo_rt/now"
    gatygo_xray_peers "$_gatygo_pid" > "$_gatygo_rt/peers"
    : > "$_gatygo_rt/moved"
    [ -f "$GATYGO_RUN/relay-addresses" ] && awk '
        FILENAME == ARGV[1] { has[$1] = 1; now[$1 " " $3] = 1; next }
        FILENAME == ARGV[2] { held[$1 " " $2] = 1; next }
        has[$1] && !now[$1 " " $3] && held[$3 " " $2] { print $1, (($3 ~ /:/) ? "[" $3 "]" : $3) ":" $2 }' \
        "$_gatygo_rt/now" "$_gatygo_rt/peers" "$GATYGO_RUN/relay-addresses" > "$_gatygo_rt/moved"
    _gatygo_relay_add "$_gatygo_rt/now"
    while read -r _gatygo_h _gatygo_a; do
        gatygo_log info "relay $_gatygo_h moved; xray is still connected to its old address $_gatygo_a"
    done < "$_gatygo_rt/moved"
    [ -s "$_gatygo_rt/moved" ]
    _gatygo_rc=$?
    rm -rf "$_gatygo_rt"
    return "$_gatygo_rc"
}

# gatygo_relay_reconnect — a new value for the xray instance (the init script hands it to procd),
# so that the next `start` restarts xray although its files did not change
gatygo_relay_reconnect() {
    mkdir -p "$GATYGO_RUN"
    echo $(($(cat "$GATYGO_RUN/reconnect" 2>/dev/null || echo 0) + 1)) > "$GATYGO_RUN/reconnect"
}
