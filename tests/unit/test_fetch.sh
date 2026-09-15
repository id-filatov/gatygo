#!/bin/sh
. "$(dirname "$0")/../lib.sh"
export GATYGO_SYSROOT="$FIXTURES/sysroot"
. "$GATYGO_LIB/config.sh"
. "$GATYGO_LIB/fetch.sh"
. "$GATYGO_LIB/headers.sh"
. "$GATYGO_LIB/subscription.sh"
tmp=$(mktemp -d)

python3 /src/tests/mock/sub_server.py 8787 "$FIXTURES/subscription.json" "$FIXTURES/geo" http://127.0.0.1:8787 &
_mock=$!
for _ in $(seq 1 50); do curl -fs -o /dev/null http://127.0.0.1:8787/log && break; sleep 0.1; done

# happy path
_code=$(gatygo_fetch http://127.0.0.1:8787/sub gatygo/0.1.0 0123456789abcdef0123456789abcdef "$tmp/body" "$tmp/hdr")
_rc=$?
assert_eq "0" "$_rc" "200 -> exit 0"
assert_eq "200" "$_code" "prints the status"
assert_eq "$(sha256sum < "$FIXTURES/subscription.json")" "$(sha256sum < "$tmp/body")" "body saved byte for byte"
assert_exit 0 "body validates as a subscription" gatygo_sub_validate "$tmp/body"
gatygo_parse_headers "$tmp/hdr" > "$tmp/h.env"; . "$tmp/h.env"
assert_eq "Example VPN" "$GATYGO_PROFILE_TITLE" "response headers are captured"
assert_eq "http://127.0.0.1:8787/geo/geosite.dat" "$GATYGO_GEOSITE_URL" "routing header parsed"

# the request carried every mandatory header
_req=$(curl -fs http://127.0.0.1:8787/log | jq -c '[.[] | select(.path == "/sub")][0].headers')
assert_eq "gatygo/0.1.0" "$(printf '%s' "$_req" | jq -r '.["user-agent"]')" "User-Agent"
assert_eq "0123456789abcdef0123456789abcdef" "$(printf '%s' "$_req" | jq -r '.["x-hwid"]')" "x-hwid"
assert_eq "OpenWrt" "$(printf '%s' "$_req" | jq -r '.["x-device-os"]')" "x-device-os"
assert_eq "25.12.5" "$(printf '%s' "$_req" | jq -r '.["x-ver-os"]')" "x-ver-os from openwrt_release"
assert_eq "qemu-qemu-virtual-machine" "$(printf '%s' "$_req" | jq -r '.["x-device-model"]')" "x-device-model from board_name"
assert_eq "*/*" "$(printf '%s' "$_req" | jq -r '.["accept"]')" "Accept"
assert_eq "identity" "$(printf '%s' "$_req" | jq -r '.["accept-encoding"]')" "Accept-Encoding identity"

# wrong UA -> the mock answers like the real panel: 200 but base64 text, which does not validate
gatygo_fetch http://127.0.0.1:8787/sub "curl/8.0" 0123456789abcdef0123456789abcdef "$tmp/body2" "$tmp/hdr2" >/dev/null
assert_exit 1 "base64 body is rejected by validate" gatygo_sub_validate "$tmp/body2"

# HTTP errors and transport errors
_code=$(gatygo_fetch http://127.0.0.1:8787/sub-broken gatygo/0.1.0 0123456789abcdef0123456789abcdef "$tmp/b3" "$tmp/h3" 2>/dev/null); _rc=$?
assert_eq "1" "$_rc" "HTTP 500 -> exit 1"
assert_eq "500" "$_code" "status printed on error"
_code=$(gatygo_fetch http://127.0.0.1:8787/redirect gatygo/0.1.0 0123456789abcdef0123456789abcdef "$tmp/b4" "$tmp/h4" 2>/dev/null); _rc=$?
assert_eq "1" "$_rc" "redirect is not followed -> exit 1"
assert_eq "302" "$_code" "redirect status reported"
_code=$(gatygo_fetch http://127.0.0.1:1/sub gatygo/0.1.0 0123456789abcdef0123456789abcdef "$tmp/b5" "$tmp/h5" 2>"$tmp/err"); _rc=$?
assert_eq "2" "$_rc" "connection refused -> exit 2"
assert_eq "" "$_code" "nothing printed when curl fails"
assert_eq "0" "$(grep -c '127.0.0.1' "$tmp/err")" "the URL/host never appears in the log line"
assert_eq "1" "$(grep -c 'curl failed' "$tmp/err")" "a generic error line is logged"

# no hwid -> no x-hwid header at all
gatygo_fetch http://127.0.0.1:8787/sub-nohwid gatygo/0.1.0 "" "$tmp/b6" "$tmp/h6" >/dev/null
_req=$(curl -fs http://127.0.0.1:8787/log | jq -c '[.[] | select(.path == "/sub-nohwid")][0].headers')
assert_eq "false" "$(printf '%s' "$_req" | jq 'has("x-hwid")')" "empty hwid -> header omitted"
assert_exit 0 "body still validates without hwid" gatygo_sub_validate "$tmp/b6"

kill $_mock 2>/dev/null; rm -rf "$tmp"
report
