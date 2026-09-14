#!/bin/sh
. "$(dirname "$0")/../lib.sh"
. "$GATYGO_LIB/subscription.sh"
tmp=$(mktemp -d)
FIX="$FIXTURES/subscription.json"

# --- validate
assert_exit 0 "fixture validates" gatygo_sub_validate "$FIX"
printf 'dmxlc3M6Ly8xMjM0QGV4YW1wbGUuY29tOjQ0Mw==' > "$tmp/base64-body.txt"
assert_exit 1 "base64 link list (wrong UA) is rejected" gatygo_sub_validate "$tmp/base64-body.txt"
jq '.[13:]' "$FIX" > "$tmp/routers-only.json"
assert_eq "9" "$(jq length "$tmp/routers-only.json")" "sanity: 9 router-only configs"
assert_exit 1 "array without balancer configs is rejected" gatygo_sub_validate "$tmp/routers-only.json"
printf '[]' > "$tmp/empty.json"
assert_exit 1 "empty array is rejected" gatygo_sub_validate "$tmp/empty.json"
printf '{"remarks":"x","routing":{"balancers":[{}]}}' > "$tmp/object.json"
assert_exit 1 "single object (not an array) is rejected" gatygo_sub_validate "$tmp/object.json"
_reason=$(gatygo_sub_validate "$tmp/base64-body.txt" 2>&1)
assert_eq "1" "$(printf '%s\n' "$_reason" | grep -c .)" "rejection prints exactly one reason line"
case $_reason in *User-Agent*) _t_ok ;; *) _t_bad "reason mentions User-Agent: $_reason" ;; esac

# --- profiles
_p=$(gatygo_sub_profiles "$FIX")
assert_eq "13" "$(printf '%s' "$_p" | jq length)" "13 balancer profiles"
assert_eq "🌐 Auto" "$(printf '%s' "$_p" | jq -r '.[0].remarks')" "first profile is the auto tile"
assert_eq "📍 Juliett" "$(printf '%s' "$_p" | jq -r '.[-1].remarks')" "last profile is Juliett"
assert_eq "Best server across all locations" "$(printf '%s' "$_p" | jq -r '.[0].description')" "description from meta.serverDescription"
assert_eq "0" "$(printf '%s' "$_p" | jq '[.[] | select(.remarks | contains("Router"))] | length')" "router-only tiles are not listed"
assert_eq '["description","remarks"]' "$(printf '%s' "$_p" | jq -c '.[0] | keys')" "profile entries carry only remarks and description"
assert_eq "[]" "$(gatygo_sub_profiles "$tmp/routers-only.json")" "no balancer configs -> empty list"

# --- select: exact match
_chosen=$(gatygo_sub_select "$FIX" "📍 Bravo" "$tmp/de.json")
_rc=$?
assert_eq "0" "$_rc" "exact match exits 0"
assert_eq "📍 Bravo" "$_chosen" "exact match prints the remarks"
assert_eq "📍 Bravo" "$(jq -r .remarks "$tmp/de.json")" "OUT holds the matching config"
assert_eq "10" "$(jq '.outbounds | length' "$tmp/de.json")" "Bravo config has 10 outbounds"

# --- select: profile exists only as a router tile (no balancer) -> fallback, exit 3
_chosen=$(gatygo_sub_select "$FIX" "📍 Bravo | Router" "$tmp/fb.json")
_rc=$?
assert_eq "3" "$_rc" "unknown profile exits 3"
assert_eq "🌐 Auto" "$_chosen" "fallback is the first balancer config"
assert_eq "🌐 Auto" "$(jq -r .remarks "$tmp/fb.json")" "OUT holds the fallback config"

# --- select: empty profile -> first balancer config, exit 0
_chosen=$(gatygo_sub_select "$FIX" "" "$tmp/empty-profile.json")
_rc=$?
assert_eq "0" "$_rc" "empty profile exits 0"
assert_eq "🌐 Auto" "$_chosen" "empty profile selects the first balancer config"

# --- select: nothing selectable
_chosen=$(gatygo_sub_select "$tmp/routers-only.json" "🌐 Auto" "$tmp/none.json")
_rc=$?
assert_eq "1" "$_rc" "no balancer config exits 1"
assert_exit 1 "OUT is not created when nothing is selectable" test -e "$tmp/none.json"

rm -rf "$tmp"
report
