#!/bin/sh
# Smoke test: the test image has the tools and fixtures every other test relies on.
. "$(dirname "$0")/../lib.sh"

assert_exit 0 "jq is installed" jq --version
assert_exit 0 "xray is installed" xray version
assert_eq "22" "$(jq 'length' "$FIXTURES/subscription.json")" "fixture has 22 configs"
assert_eq "13" "$(jq '[.[] | select((.routing.balancers // []) | length > 0)] | length' \
    "$FIXTURES/subscription.json")" "fixture has 13 balancer configs"
assert_exit 0 "geosite.dat is present" test -s "$XRAY_LOCATION_ASSET/geosite.dat"
assert_exit 0 "geoip.dat is present" test -s "$XRAY_LOCATION_ASSET/geoip.dat"

report
