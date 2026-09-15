#!/bin/sh
. "$(dirname "$0")/../lib.sh"
. "$GATYGO_LIB/transform.sh"
. "$GATYGO_LIB/nodes.sh"
tmp=$(mktemp -d)
jq '.[0]' "$FIXTURES/subscription.json" > "$tmp/auto.json"
gatygo_transform "$tmp/auto.json" "$tmp/xray.json" 12345 5353 255 warning /tmp/x.log
jq '.[15]' "$FIXTURES/subscription.json" > "$tmp/single.json"
gatygo_transform "$tmp/single.json" "$tmp/xray-single.json" 12345 5353 255 warning /tmp/x.log

# --- with canned API answers
_n=$(XRAY_STUB_DIR="$FIXTURES/xray-api" gatygo_nodes "$tmp/xray.json")
assert_eq "true" "$(printf '%s' "$_n" | jq .api)" "api reachable"
assert_eq "balancer" "$(printf '%s' "$_n" | jq -r .balancer)" "balancer tag from the config"
assert_eq "25" "$(printf '%s' "$_n" | jq '.nodes | length')" "24 proxies + direct; block and dns-out skipped"
assert_eq "proxy" "$(printf '%s' "$_n" | jq -r '.nodes[0].tag')" "config order kept"
assert_eq "relay-1.example.com" "$(printf '%s' "$_n" | jq -r '.nodes[0].address')" "address from vnext"
assert_eq "380000 3100000" "$(printf '%s' "$_n" | jq -r '.nodes[0] | "\(.up) \(.down)"')" "traffic counters as numbers"
assert_eq "412000 0" "$(printf '%s' "$_n" | jq -r '.nodes[] | select(.tag == "proxy-2") | "\(.up) \(.down)"')" "missing value counts as 0"
assert_eq "0 9800000" "$(printf '%s' "$_n" | jq -r '.nodes[] | select(.tag == "direct") | "\(.up) \(.down)"')" "direct is listed with its traffic"
assert_eq "" "$(printf '%s' "$_n" | jq -r '.nodes[] | select(.tag == "direct") | .address')" "direct has no address"
assert_eq "proxy proxy-2 proxy-3" "$(printf '%s' "$_n" | jq -r '[.nodes[] | select(.in_use) | .tag] | join(" ")')" "in_use from the balancer selection"

# --- API unreachable (nothing listens on the test port): still the node list, zeros, not in use
_n=$(GATYGO_API=127.0.0.1:1 gatygo_nodes "$tmp/xray.json")
assert_eq "false" "$(printf '%s' "$_n" | jq .api)" "api unreachable"
assert_eq "25" "$(printf '%s' "$_n" | jq '.nodes | length')" "nodes still listed"
assert_eq "0" "$(printf '%s' "$_n" | jq '[.nodes[] | select(.in_use or .up > 0 or .down > 0)] | length')" "no traffic, nothing in use"

# --- single-server config: no balancer, bi not consulted
_n=$(XRAY_STUB_DIR="$FIXTURES/xray-api" gatygo_nodes "$tmp/xray-single.json")
assert_eq "null" "$(printf '%s' "$_n" | jq .balancer)" "no balancer"
assert_eq "2" "$(printf '%s' "$_n" | jq '.nodes | length')" "proxy + direct"
assert_eq "0" "$(printf '%s' "$_n" | jq '[.nodes[] | select(.in_use)] | length')" "nothing marked in use without a balancer"

rm -rf "$tmp"
report
