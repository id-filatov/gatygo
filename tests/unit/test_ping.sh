#!/bin/sh
# gatygo ping: the response time of every country, measured from the router straight to the
# servers. The "servers" here are the mock panel's port (it answers) and closed ports (they
# refuse): the probe runs exactly as on the router.
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state" GATYGO_RUN="$tmp/run"
mkdir -p "$GATYGO_STATE" "$GATYGO_RUN"
. "$GATYGO_LIB/ping.sh"

python3 /src/tests/mock/sub_server.py 8791 "$FIXTURES/subscription.json" "$tmp" http://127.0.0.1:8791 >/dev/null 2>&1 &
_mock=$!
for _ in $(seq 1 50); do curl -fs -o /dev/null http://127.0.0.1:8791/log && break; sleep 0.1; done

cat > "$tmp/sub.json" <<'EOF'
[ { "remarks": "📍 Dead", "outbounds": [ { "protocol": "vless", "settings": { "vnext": [ { "address": "127.0.0.1", "port": 1 } ] } } ] },
  { "remarks": "🌐 Auto", "routing": { "balancers": [ { "tag": "balancer" } ] }, "outbounds": [
      { "protocol": "vless", "settings": { "vnext": [ { "address": "127.0.0.1", "port": 1 } ] } },
      { "protocol": "vless", "settings": { "vnext": [ { "address": "127.0.0.1", "port": 8791 } ] } },
      { "tag": "direct", "protocol": "freedom" }, { "tag": "block", "protocol": "blackhole" } ] },
  { "remarks": "📍 Trojan", "outbounds": [ { "protocol": "trojan", "settings": { "servers": [ { "address": "127.0.0.1", "port": "8791" } ] } } ] },
  { "remarks": "📍 Flat", "outbounds": [ { "protocol": "vless", "settings": { "address": "127.0.0.1", "port": 8791 } } ] },
  { "remarks": "📍 Odd", "outbounds": [ { "protocol": "vless", "settings": { "vnext": [ { "address": "bad host;reboot", "port": 443 } ] } },
                                         { "protocol": "vless", "settings": { "vnext": [ { "address": "-Kfile", "port": "4 43" } ] } } ] },
  { "remarks": "📍 Empty", "outbounds": [] } ]
EOF

# --- the servers of a subscription: every address once, whatever the protocol spells it like
assert_eq "127.0.0.1 1
127.0.0.1 8791" "$(gatygo_ping_endpoints "$tmp/sub.json")" "each server once; vnext, servers and flat settings; odd addresses and ports left out"
assert_eq "12 12" "$(gatygo_ping_endpoints "$FIXTURES/subscription.json" | wc -l | tr -d ' ') $(gatygo_ping_endpoints "$FIXTURES/subscription.json" | grep -c '^relay-[0-9]*\.example\.com 443$')" "the fixture's 12 relays"

# --- one server: the TCP connect time, the better of two tries; no second try at a dead one
curl() { echo x >> "$tmp/curl-calls"; command curl "$@"; }
_ms=$(gatygo_ping_probe 127.0.0.1 8791)
assert_exit 0 "a server that answers has a time in ms, at least 1" sh -c "[ '$_ms' -ge 1 ] && [ '$_ms' -lt 1000 ]"
assert_eq "2" "$(wc -l < "$tmp/curl-calls" | tr -d ' ')" "measured twice (the first try pays for the DNS cache)"
: > "$tmp/curl-calls"
_t0=$(date +%s)
assert_eq "" "$(gatygo_ping_probe 127.0.0.1 1)" "no answer -> nothing"
assert_eq "1" "$(wc -l < "$tmp/curl-calls" | tr -d ' ')" "a dead server is tried once"
[ $(( $(date +%s) - _t0 )) -le 2 ] && _t_ok || _t_bad "a refused connection fails fast"

# --- a run: a country is as fast as its fastest server; the order is the page's (balancers first)
: > "$tmp/curl-calls"
_out=$(gatygo_ping_run "$tmp/sub.json")
assert_eq '["🌐 Auto","📍 Dead","📍 Trojan","📍 Flat","📍 Odd"]' "$(printf '%s' "$_out" | jq -c 'map(.remarks)')" "every runnable profile, in the page's order"
assert_eq '["number","null","number","number","null"]' "$(printf '%s' "$_out" | jq -c 'map(.ms | type)')" "a time where a server answered, null where none did"
assert_eq "3" "$(wc -l < "$tmp/curl-calls" | tr -d ' ')" "a server shared by profiles is measured once (2 tries at the live one, 1 at the dead one)"
unset -f curl

# --- more servers than one batch
jq -n '[{remarks: "📍 Many", outbounds: ([range(2; 22) | {protocol: "vless", settings: {vnext: [{address: "127.0.0.1", port: .}]}}]
        + [{protocol: "vless", settings: {vnext: [{address: "127.0.0.1", port: 8791}]}}])}]' > "$tmp/many.json"
assert_eq "21" "$(gatygo_ping_endpoints "$tmp/many.json" | wc -l | tr -d ' ')" "21 servers"
assert_eq "number" "$(gatygo_ping_run "$tmp/many.json" | jq -r '.[0].ms | type')" "the live one is found among 21"

# --- the kept result: in the run dir (tmpfs), with its time; old or missing means a run is due
cp "$tmp/sub.json" "$GATYGO_STATE/subscription.json"
assert_eq '{"time":null,"measuring":false,"profiles":[]}' "$(gatygo_ping_kept 300)" "nothing kept yet"
assert_exit 1 "nothing kept -> a run is due" gatygo_ping_kept 300
gatygo_ping_store '[{"remarks":"🌐 Auto","ms":12}]' > "$tmp/stored.json"
assert_eq '{"measuring":false,"profiles":[{"remarks":"🌐 Auto","ms":12}]}' "$(jq -c 'del(.time)' "$tmp/stored.json")" "store prints what it keeps"
assert_exit 0 "the result has its time" jq -e '.time > 1700000000' "$tmp/stored.json"
assert_exit 0 "kept in the run dir (tmpfs), not in flash" test -s "$GATYGO_RUN/ping.json"
assert_eq "12" "$(gatygo_ping_kept 300 | jq '.profiles[0].ms')" "a recent result is given back"
assert_exit 0 "a recent result -> no run is due" gatygo_ping_kept 300
assert_eq "12" "$(gatygo_ping_kept 0 | jq '.profiles[0].ms')" "an old result is still given back"
assert_exit 1 "an old result -> a run is due" gatygo_ping_kept 0
assert_eq "false" "$(gatygo_ping_kept 300 | jq .measuring)" "no run in progress"
mkdir -p "$GATYGO_RUN/ping.lock"; echo $$ > "$GATYGO_RUN/ping.lock/pid"
assert_eq "true" "$(gatygo_ping_kept 300 | jq .measuring)" "a run in progress is reported"

# --- CLI
CLI=/src/gatygo/files/gatygo
_a=$(sh "$CLI" ping)
assert_eq "12" "$(printf '%s' "$_a" | jq '.profiles[0].ms')" "cli: while another run holds the lock, the kept result is printed"
rm -rf "$GATYGO_RUN/ping.lock"
_a=$(sh "$CLI" ping)
assert_eq 'false 5 number' "$(printf '%s' "$_a" | jq -r '"\(.measuring) \(.profiles | length) \(.profiles[0].ms | type)"')" "cli: ping measures and prints"
assert_exit 1 "cli: the lock is released after the run" test -e "$GATYGO_RUN/ping.lock"
assert_eq "$(printf '%s' "$_a" | jq -c .)" "$(sh "$CLI" ping kept | jq -c .)" "cli: ping kept prints the same without measuring"
rm -f "$GATYGO_STATE/subscription.json" "$GATYGO_RUN/ping.json"
assert_eq '{"time":null,"measuring":false,"profiles":[]}' "$(sh "$CLI" ping)" "cli: no subscription -> nothing to measure"
assert_exit 0 "cli: no subscription -> no run is due either" sh "$CLI" ping kept

kill "$_mock" 2>/dev/null
rm -rf "$tmp"
report
