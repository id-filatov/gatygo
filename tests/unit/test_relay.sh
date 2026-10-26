#!/bin/sh
# A relay that moved to a new address while xray stays on the old one (lib/relay.sh). DNS answers
# come from the nslookup stub, xray's connections from the netstat stub (xray is pid 4242, ubus stub).
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_RUN="$tmp/run" NSLOOKUP_STUB_FILE="$tmp/dns" NETSTAT_STUB_FILE="$tmp/tcp" UBUS_STUB_RUNNING=1
: > "$NSLOOKUP_STUB_FILE"; : > "$NETSTAT_STUB_FILE"
. "$GATYGO_LIB/relay.sh"
_seen() { sort "$GATYGO_RUN/relay-addresses" 2>/dev/null | tr '\n' ',' | sed 's/,$//'; }
# _tcp PID/NAME STATE ADDRESS:PORT... — the connections netstat shows
_tcp() {
    _who=$1 _st=$2; shift 2
    for _peer; do printf 'tcp        0      0 192.168.1.1:40000         %-25s %-11s %s\n' "$_peer" "$_st" "$_who"; done >> "$NETSTAT_STUB_FILE"
}

cat > "$tmp/xray.json" <<'EOF'
{ "outbounds": [
  { "tag": "proxy", "protocol": "vless", "settings": { "vnext": [ { "address": "ru1.example.com", "port": 2096 } ] } },
  { "tag": "proxy-2", "protocol": "vless", "settings": { "vnext": [ { "address": "ru2.example.com", "port": 443 }, { "address": "ru1.example.com", "port": 2096 } ] } },
  { "tag": "proxy-3", "protocol": "trojan", "settings": { "servers": [ { "address": "tr.example.com", "port": "8443" } ] } },
  { "tag": "proxy-4", "protocol": "vless", "settings": { "address": "flat.example.com", "port": 443 } },
  { "tag": "proxy-5", "protocol": "vless", "settings": { "vnext": [ { "address": "203.0.113.9", "port": 443 }, { "address": "2001:db8::9", "port": 443 } ] } },
  { "tag": "proxy-6", "protocol": "vless", "settings": { "vnext": [ { "address": "bad host;reboot", "port": 443 }, { "address": "-Kfile", "port": 443 },
                                                                    { "address": "x.example.com", "port": "4 43" } ] } },
  { "tag": "direct", "protocol": "freedom" }, { "tag": "block", "protocol": "blackhole" }, { "tag": "dns-out", "protocol": "dns" } ] }
EOF

# --- the relays xray dials by name: every one once, whatever the protocol spells it like
assert_eq "flat.example.com 443
ru1.example.com 2096
ru2.example.com 443
tr.example.com 8443" "$(gatygo_relay_endpoints "$tmp/xray.json")" "named relays once each; vnext, servers and flat settings; IP literals, odd names and ports left out"

# --- the addresses the system resolver gives a name (dnsmasq, as xray asks it)
printf 'ru1.example.com 198.51.100.1\nru1.example.com 2001:db8::1\n' > "$NSLOOKUP_STUB_FILE"
assert_eq "198.51.100.1
2001:db8::1" "$(gatygo_resolve ru1.example.com)" "IPv4 and IPv6 answers, not the resolver's own address"
assert_eq "" "$(gatygo_resolve nowhere.example.com)" "no answer -> nothing"

# --- xray's established connections, nobody else's
_tcp 4242/xray ESTABLISHED 198.51.100.1:2096 2001:db8::1:443 ::ffff:198.51.100.5:443
_tcp 4242/xray TIME_WAIT 198.51.100.2:2096
_tcp - TIME_WAIT 198.51.100.3:2096
_tcp 999/curl ESTABLISHED 198.51.100.4:2096
_tcp 42420/other ESTABLISHED 198.51.100.6:2096
assert_eq "198.51.100.1 2096
2001:db8::1 443
198.51.100.5 443" "$(gatygo_xray_peers 4242)" "established only, of that pid only; IPv6 split at the last colon, IPv4-mapped unwrapped"

# --- noting the addresses: what the names have now joins what they had
: > "$NETSTAT_STUB_FILE"
printf 'ru1.example.com 198.51.100.1\nru2.example.com 198.51.100.7\n' > "$NSLOOKUP_STUB_FILE"
gatygo_relay_note "$tmp/xray.json"
assert_eq "ru1.example.com 2096 198.51.100.1,ru2.example.com 443 198.51.100.7" "$(_seen)" "every named relay with an answer, by port"
printf 'ru1.example.com 198.51.100.2\nru2.example.com 198.51.100.7\n' > "$NSLOOKUP_STUB_FILE"
gatygo_relay_note "$tmp/xray.json"
assert_eq "ru1.example.com 2096 198.51.100.1,ru1.example.com 2096 198.51.100.2,ru2.example.com 443 198.51.100.7" "$(_seen)" "a new address is added, the old one kept"

# --- moved: xray still holds the address the name had and no longer has
rm -f "$GATYGO_RUN/relay-addresses"
printf 'ru1.example.com 198.51.100.1\nru2.example.com 198.51.100.7\n' > "$NSLOOKUP_STUB_FILE"
gatygo_relay_note "$tmp/xray.json"
printf 'ru1.example.com 198.51.100.2\nru2.example.com 198.51.100.7\n' > "$NSLOOKUP_STUB_FILE"
_tcp 4242/xray ESTABLISHED 198.51.100.1:2096 198.51.100.7:443
: > "$SYSLOG_STUB_FILE"
assert_exit 0 "xray on the old address of a moved relay -> moved" gatygo_relay_moved "$tmp/xray.json"
assert_eq "1" "$(grep -c '\[info\] relay ru1.example.com moved; xray is still connected to its old address 198.51.100.1:2096$' "$SYSLOG_STUB_FILE")" "the log says which relay and where xray still is"
assert_eq "ru1.example.com 2096 198.51.100.1,ru1.example.com 2096 198.51.100.2,ru2.example.com 443 198.51.100.7" "$(_seen)" "the check notes the new address too"

# --- not moved
: > "$NETSTAT_STUB_FILE"; _tcp 4242/xray ESTABLISHED 198.51.100.2:2096 198.51.100.7:443
assert_exit 1 "xray on the new address -> not moved" gatygo_relay_moved "$tmp/xray.json"
: > "$NETSTAT_STUB_FILE"; _tcp 4242/xray ESTABLISHED 198.51.100.1:2096
printf 'ru1.example.com 198.51.100.2\nru1.example.com 198.51.100.1\n' > "$NSLOOKUP_STUB_FILE"
assert_exit 1 "the old address is still among the answers (a name with several) -> not moved" gatygo_relay_moved "$tmp/xray.json"
: > "$NSLOOKUP_STUB_FILE"
assert_exit 1 "no answer for the name (DNS down) -> not moved" gatygo_relay_moved "$tmp/xray.json"
printf 'ru1.example.com 198.51.100.2\nru2.example.com 198.51.100.8\n' > "$NSLOOKUP_STUB_FILE"
: > "$NETSTAT_STUB_FILE"; _tcp 4242/xray ESTABLISHED 198.51.100.2:2096 192.0.2.50:443 198.51.100.1:443
assert_exit 1 "connections on a relay's port to addresses no relay had (direct traffic), or to an old address on another port -> not moved" gatygo_relay_moved "$tmp/xray.json"
: > "$NETSTAT_STUB_FILE"; _tcp 999/curl ESTABLISHED 198.51.100.1:2096; _tcp - TIME_WAIT 198.51.100.1:2096
assert_exit 1 "the old address held by another process, or closed -> not moved" gatygo_relay_moved "$tmp/xray.json"
: > "$NETSTAT_STUB_FILE"; _tcp 4242/xray ESTABLISHED 198.51.100.1:2096
UBUS_STUB_RUNNING=0
assert_exit 1 "xray not running -> not moved" gatygo_relay_moved "$tmp/xray.json"
UBUS_STUB_RUNNING=1
assert_exit 0 "and the same running -> moved" gatygo_relay_moved "$tmp/xray.json"

# --- the restart: a new value every time for the procd instance
_r1=$(gatygo_relay_reconnect; cat "$GATYGO_RUN/reconnect")
_r2=$(gatygo_relay_reconnect; cat "$GATYGO_RUN/reconnect")
assert_exit 0 "each reconnect writes a different value" test -n "$_r1" -a "$_r1" != "$_r2"

rm -rf "$tmp"
report
