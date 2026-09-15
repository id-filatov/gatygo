#!/bin/sh
. "$(dirname "$0")/../lib.sh"
. "$GATYGO_LIB/subscription.sh"
tmp=$(mktemp -d)
FIX="$FIXTURES/subscription.json"

# --- validate: any array with at least one config that has outbounds
assert_exit 0 "fixture validates" gatygo_sub_validate "$FIX"
printf 'dmxlc3M6Ly8xMjM0QGV4YW1wbGUuY29tOjQ0Mw==' > "$tmp/base64-body.txt"
assert_exit 1 "base64 link list (wrong UA) is rejected" gatygo_sub_validate "$tmp/base64-body.txt"
jq '.[13:]' "$FIX" > "$tmp/singles-only.json"
assert_eq "9" "$(jq length "$tmp/singles-only.json")" "sanity: 9 single-server configs"
assert_exit 0 "array without balancer configs is accepted" gatygo_sub_validate "$tmp/singles-only.json"
printf '[]' > "$tmp/empty.json"
assert_exit 1 "empty array is rejected" gatygo_sub_validate "$tmp/empty.json"
printf '[{"remarks":"x","routing":{"balancers":[{}]}}]' > "$tmp/no-outbounds.json"
assert_exit 1 "config without outbounds is rejected" gatygo_sub_validate "$tmp/no-outbounds.json"
printf '{"remarks":"x","outbounds":[{}]}' > "$tmp/object.json"
assert_exit 1 "single object (not an array) is rejected" gatygo_sub_validate "$tmp/object.json"
_reason=$(gatygo_sub_validate "$tmp/base64-body.txt" 2>&1)
assert_eq "1" "$(printf '%s\n' "$_reason" | grep -c .)" "rejection prints exactly one reason line"
case $_reason in *User-Agent*) _t_ok ;; *) _t_bad "reason mentions User-Agent: $_reason" ;; esac

# --- profiles: everything, balancer configs first
_p=$(gatygo_sub_profiles "$FIX")
assert_eq "22" "$(printf '%s' "$_p" | jq length)" "all 22 configs are listed"
assert_eq "🌐 Auto" "$(printf '%s' "$_p" | jq -r '.[0].remarks')" "first profile is the auto tile"
assert_eq "📍 Juliett" "$(printf '%s' "$_p" | jq -r '.[12].remarks')" "last balancer profile is Juliett"
assert_eq "⬇️ Router profiles" "$(printf '%s' "$_p" | jq -r '.[13].remarks')" "single-server configs follow"
assert_eq "13" "$(printf '%s' "$_p" | jq '[.[] | select(.balanced)] | length')" "13 flagged balanced"
assert_eq "true" "$(printf '%s' "$_p" | jq '[.[:13][] | .balanced] | all')" "the first 13 are the balanced ones"
assert_eq "false" "$(printf '%s' "$_p" | jq '[.[13:][] | .balanced] | any')" "the rest are not"
assert_eq "Best server across all locations" "$(printf '%s' "$_p" | jq -r '.[0].description')" "description from meta.serverDescription"
assert_eq '["balanced","description","remarks"]' "$(printf '%s' "$_p" | jq -c '.[0] | keys')" "profile entries carry remarks, description and balanced"
assert_eq "9" "$(gatygo_sub_profiles "$tmp/singles-only.json" | jq length)" "single-server subscription lists all of them"

# --- select: exact match, balanced
_chosen=$(gatygo_sub_select "$FIX" "📍 Bravo" "$tmp/de.json")
_rc=$?
assert_eq "0" "$_rc" "exact match exits 0"
assert_eq "📍 Bravo" "$_chosen" "exact match prints the remarks"
assert_eq "📍 Bravo" "$(jq -r .remarks "$tmp/de.json")" "OUT holds the matching config"
assert_eq "10" "$(jq '.outbounds | length' "$tmp/de.json")" "Bravo config has 10 outbounds"

# --- select: exact match, single server
_chosen=$(gatygo_sub_select "$FIX" "📍 Bravo | Router" "$tmp/single.json")
_rc=$?
assert_eq "0" "$_rc" "single-server profile is selectable"
assert_eq "📍 Bravo | Router" "$(jq -r .remarks "$tmp/single.json")" "OUT holds the single-server config"

# --- select: unknown profile -> fallback to the first listed, exit 3
_chosen=$(gatygo_sub_select "$FIX" "📍 Missing" "$tmp/fb.json")
_rc=$?
assert_eq "3" "$_rc" "unknown profile exits 3"
assert_eq "🌐 Auto" "$_chosen" "fallback is the first balancer config"
assert_eq "🌐 Auto" "$(jq -r .remarks "$tmp/fb.json")" "OUT holds the fallback config"
_chosen=$(gatygo_sub_select "$tmp/singles-only.json" "🌐 Auto" "$tmp/fb2.json")
_rc=$?
assert_eq "3" "$_rc" "unknown profile in a single-server subscription exits 3"
assert_eq "⬇️ Router profiles" "$_chosen" "fallback is the first config when nothing is balanced"

# --- select: empty profile -> first listed, exit 0
_chosen=$(gatygo_sub_select "$FIX" "" "$tmp/empty-profile.json")
_rc=$?
assert_eq "0" "$_rc" "empty profile exits 0"
assert_eq "🌐 Auto" "$_chosen" "empty profile selects the first balancer config"

# --- select: nothing runnable
_chosen=$(gatygo_sub_select "$tmp/no-outbounds.json" "x" "$tmp/none.json")
_rc=$?
assert_eq "1" "$_rc" "no runnable config exits 1"
assert_exit 1 "OUT is not created when nothing is selectable" test -e "$tmp/none.json"

rm -rf "$tmp"
report
