#!/bin/sh
# gatygo check: services probed through the tunnel's local SOCKS inbound. A real xray (socks in,
# freedom out) and the mock panel as the "service": the probe runs exactly as on the router.
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state" GATYGO_RUN="$tmp/run"
mkdir -p "$GATYGO_STATE" "$GATYGO_RUN"
. "$GATYGO_LIB/check.sh"

python3 /src/tests/mock/sub_server.py 8790 "$FIXTURES/subscription.json" "$tmp" http://127.0.0.1:8790 &
_mock=$!
cat > "$tmp/xray.json" <<'EOF'
{ "log": { "loglevel": "none" },
  "inbounds": [ { "tag": "check", "protocol": "socks", "listen": "127.0.0.1", "port": 10808, "settings": { "auth": "noauth", "udp": false } } ],
  "outbounds": [ { "protocol": "freedom" } ] }
EOF
/usr/local/bin/xray run -c "$tmp/xray.json" >/dev/null 2>&1 &
_xray=$!
for _ in $(seq 1 50); do curl -fs -o /dev/null http://127.0.0.1:8790/log && nc -z 127.0.0.1 10808 2>/dev/null && break; sleep 0.1; done

# --- the shipped list: what the owner chose, one "Name URL" per line
assert_eq "YouTube Instagram Telegram WhatsApp" "$(cut -d' ' -f1 "$GATYGO_LIB/check.list" | tr '\n' ' ' | sed 's/ $//')" "the shipped list names the four services"
assert_eq "4" "$(grep -c '^[A-Za-z]* https://' "$GATYGO_LIB/check.list")" "every entry is a name and an https URL"

# --- a run: any HTTP answer counts, no answer is null, the list order is kept
printf '%s\n' "Alpha http://127.0.0.1:8790/log" "Dead http://127.0.0.1:1/" "Beta http://127.0.0.1:8790/sub-broken" > "$tmp/list"
_out=$(GATYGO_CHECK_LIST="$tmp/list" gatygo_check_run 10808)
assert_eq '["Alpha","Dead","Beta"]' "$(printf '%s' "$_out" | jq -c 'map(.name)')" "results follow the list order"
assert_exit 0 "a service that answers has a time in ms" sh -c "printf '%s' '$_out' | jq -e '.[0].ms | type == \"number\" and . >= 0 and . < 3000' >/dev/null"
assert_eq "null" "$(printf '%s' "$_out" | jq -c '.[1].ms')" "no answer -> null"
assert_exit 0 "an HTTP error is still an answer (the mock's 500)" sh -c "printf '%s' '$_out' | jq -e '.[2].ms | type == \"number\"' >/dev/null"

# --- nothing listens on the SOCKS port: every service is null, quickly
_t0=$(date +%s)
_out=$(GATYGO_CHECK_LIST="$tmp/list" gatygo_check_run 10809)
assert_eq '[null,null,null]' "$(printf '%s' "$_out" | jq -c 'map(.ms)')" "no tunnel -> no answers (so the answers above did come through the SOCKS inbound)"
[ $(( $(date +%s) - _t0 )) -le 3 ] && _t_ok || _t_bad "a dead SOCKS port fails fast"

# --- the cache: per profile, with an age limit
gatygo_check_store "📍 Bravo" '[{"name":"Alpha","ms":12}]' > "$tmp/stored.json"
assert_eq '{"available":true,"profile":"📍 Bravo","services":[{"name":"Alpha","ms":12}]}' "$(jq -c 'del(.time)' "$tmp/stored.json")" "store prints what it keeps"
assert_exit 0 "the result has its time" jq -e '.time > 1700000000' "$tmp/stored.json"
assert_exit 0 "kept in the run dir (tmpfs), not in flash" test -s "$GATYGO_RUN/check.json"
assert_eq "12" "$(gatygo_check_cached "📍 Bravo" 300 | jq '.services[0].ms')" "a fresh result for the same profile is reused"
assert_exit 1 "another profile -> not reused" gatygo_check_cached "📍 Alpha" 300
assert_exit 1 "too old -> not reused" gatygo_check_cached "📍 Bravo" 0
rm -f "$GATYGO_RUN/check.json"
assert_exit 1 "no cache -> not reused" gatygo_check_cached "📍 Bravo" 300

# --- CLI: available only with a running xray whose config has the inbound; fresh really runs
CLI=/src/gatygo/files/gatygo
cp "$tmp/xray.json" "$GATYGO_STATE/xray.json"; printf '%s\n' "📍 Bravo" > "$GATYGO_STATE/profile"
export GATYGO_CHECK_LIST="$tmp/list"
assert_eq '{"available":false}' "$(UBUS_STUB_RUNNING=0 sh "$CLI" check)" "cli: xray not running -> not available"
_a=$(UBUS_STUB_RUNNING=1 sh "$CLI" check)
assert_eq 'true 📍 Bravo 3' "$(printf '%s' "$_a" | jq -r '"\(.available) \(.profile) \(.services | length)"')" "cli: a run for the profile in use"
sleep 1
assert_eq "$(printf '%s' "$_a" | jq .time)" "$(UBUS_STUB_RUNNING=1 sh "$CLI" check | jq .time)" "cli: a recent result is reused"
_c=$(UBUS_STUB_RUNNING=1 sh "$CLI" check fresh | jq .time)
[ "$_c" -gt "$(printf '%s' "$_a" | jq .time)" ] && _t_ok || _t_bad "cli: fresh runs again ($_c)"
jq '.inbounds = []' "$tmp/xray.json" > "$GATYGO_STATE/xray.json"
assert_eq '{"available":false}' "$(UBUS_STUB_RUNNING=1 sh "$CLI" check fresh)" "cli: a config from before the check inbound -> not available"

kill "$_xray" "$_mock" 2>/dev/null
rm -rf "$tmp"
report
