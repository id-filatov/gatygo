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
_code=$(gatygo_fetch http://127.0.0.1:8787/sub "Happ/3.0.0 (gatygo/0.1.0)" 0123456789abcdef0123456789abcdef "$tmp/body" "$tmp/hdr")
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
assert_eq "Happ/3.0.0 (gatygo/0.1.0)" "$(printf '%s' "$_req" | jq -r '.["user-agent"]')" "User-Agent"
assert_eq "0123456789abcdef0123456789abcdef" "$(printf '%s' "$_req" | jq -r '.["x-hwid"]')" "x-hwid"
assert_eq "OpenWrt" "$(printf '%s' "$_req" | jq -r '.["x-device-os"]')" "x-device-os"
assert_eq "25.12.5" "$(printf '%s' "$_req" | jq -r '.["x-ver-os"]')" "x-ver-os from openwrt_release"
assert_eq "qemu-qemu-virtual-machine" "$(printf '%s' "$_req" | jq -r '.["x-device-model"]')" "x-device-model from board_name"
assert_eq "*/*" "$(printf '%s' "$_req" | jq -r '.["accept"]')" "Accept"
assert_eq "identity" "$(printf '%s' "$_req" | jq -r '.["accept-encoding"]')" "Accept-Encoding identity"

# a name the server does not know -> the mock answers like a real server: 200 but base64 text,
# which does not validate; the same name on <link>/json gets Xray JSON
gatygo_fetch http://127.0.0.1:8787/sub gatygo/0.1.0 0123456789abcdef0123456789abcdef "$tmp/body2" "$tmp/hdr2" >/dev/null
assert_exit 1 "base64 body is rejected by validate" gatygo_sub_validate "$tmp/body2"
gatygo_fetch http://127.0.0.1:8787/sub/json gatygo/0.1.0 0123456789abcdef0123456789abcdef "$tmp/body2" "$tmp/hdr2" >/dev/null
assert_exit 0 "the same name on /json gets Xray JSON" gatygo_sub_validate "$tmp/body2"

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
gatygo_fetch http://127.0.0.1:8787/sub-nohwid "Happ/3.0.0 (gatygo/0.1.0)" "" "$tmp/b6" "$tmp/h6" >/dev/null
_req=$(curl -fs http://127.0.0.1:8787/log | jq -c '[.[] | select(.path == "/sub-nohwid")][0].headers')
assert_eq "false" "$(printf '%s' "$_req" | jq 'has("x-hwid")')" "empty hwid -> header omitted"
assert_exit 0 "body still validates without hwid" gatygo_sub_validate "$tmp/b6"

# a server that lies dead (no answer to the connection) is given up on in 10 s, not in --max-time:
# four tries of 30 s kept the countries on the page locked for over two minutes
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho "$*" > "%s/curl.args"\nexec /usr/bin/curl "$@"\n' "$tmp" > "$tmp/bin/curl"; chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH" gatygo_fetch http://127.0.0.1:8787/sub gatygo/0.1.0 "" "$tmp/b7" "$tmp/h7" >/dev/null
case " $(cat "$tmp/curl.args") " in *" --connect-timeout 10 "*) _t_ok ;; *) _t_bad "curl waits for the connection at most 10 s: $(cat "$tmp/curl.args")" ;; esac

# --- the ways of asking for the subscription, in the order they are tried
export GATYGO_STATE="$tmp/state"; mkdir -p "$GATYGO_STATE"
GATYGO_VERSION=0.1.0
assert_eq "mixed mixed-json gatygo happ v2rayng v2rayn streisand" "$(gatygo_way_list | tr '\n' ' ' | sed 's/ $//')" "the ways in order"
assert_eq "v2rayn mixed mixed-json gatygo happ v2rayng streisand" "$(gatygo_way_list v2rayn | tr '\n' ' ' | sed 's/ $//')" "the saved way first, not twice"
assert_eq "mixed mixed-json gatygo happ v2rayng v2rayn streisand" "$(gatygo_way_list nope | tr '\n' ' ' | sed 's/ $//')" "an unknown saved way is left out"
assert_eq "Happ/3.0.0 (gatygo/0.1.0)|Happ/3.0.0 (gatygo/0.1.0)|gatygo/0.1.0|Happ/3.0.0|v2rayNG/1.10.5|v2rayN/7.13.2|Streisand/1.6.40" \
    "$(for k in $(gatygo_way_list); do gatygo_way_ua "$k"; done | tr '\n' '|' | sed 's/|$//')" "each way's User-Agent"
assert_exit 1 "an unknown way has no User-Agent" gatygo_way_ua nope
assert_eq "https://h.example/p/t" "$(gatygo_way_url mixed https://h.example/p/t)" "a way without /json: the link as is"
assert_eq "https://h.example/p/t/json" "$(gatygo_way_url mixed-json https://h.example/p/t)" "/json at the end of the path"
assert_eq "https://h.example/p/t/json" "$(gatygo_way_url mixed-json https://h.example/p/t/)" "no double slash"
assert_eq "https://h.example/p/t/json?x=1&y=2" "$(gatygo_way_url mixed-json 'https://h.example/p/t?x=1&y=2')" "the query string stays after /json"
assert_eq "https://h.example/p/t/json#f" "$(gatygo_way_url mixed-json 'https://h.example/p/t#f')" "so does a fragment"
assert_eq "https://h.example/p/json/json" "$(gatygo_way_url mixed-json https://h.example/p/json)" "a link that ends in /json gets another one"

# the way that worked, kept for one link: its fingerprint, never the link itself
L=https://panel.example.com/sub/SECRETTOKEN
assert_eq "" "$(gatygo_way_saved "$L")" "nothing saved yet"
gatygo_way_save happ "$L"
assert_eq "happ" "$(gatygo_way_saved "$L")" "the saved way for the same link"
assert_eq "" "$(gatygo_way_saved https://panel.example.com/sub/OTHER)" "another link: nothing"
assert_eq "0" "$(grep -c 'panel.example.com\|SECRETTOKEN' "$GATYGO_STATE/sub-way.env")" "the link is not in the file"
assert_eq "-rw-------" "$(ls -l "$GATYGO_STATE/sub-way.env" | cut -c1-10)" "the file is 0600"
_ino=$(ls -i "$GATYGO_STATE/sub-way.env" | awk '{print $1}')
gatygo_way_save happ "$L"
assert_eq "$_ino" "$(ls -i "$GATYGO_STATE/sub-way.env" | awk '{print $1}')" "the same way again: the file is not rewritten"
gatygo_way_save mixed-json "$L"
assert_eq "mixed-json" "$(gatygo_way_saved "$L")" "another way replaces it"

kill $_mock 2>/dev/null; rm -rf "$tmp"
report
