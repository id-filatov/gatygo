#!/bin/sh
. "$(dirname "$0")/../lib.sh"
. "$GATYGO_LIB/headers.sh"
tmp=$(mktemp -d)

# Unset every output variable so a missing line would be caught as empty.
_reset() {
    unset GATYGO_CONTENT_TYPE GATYGO_PROFILE_TITLE GATYGO_UPDATE_INTERVAL \
        GATYGO_USERINFO_UPLOAD GATYGO_USERINFO_DOWNLOAD GATYGO_USERINFO_TOTAL GATYGO_USERINFO_EXPIRE \
        GATYGO_GEOSITE_URL GATYGO_GEOIP_URL GATYGO_HWID_MAX_DEVICES GATYGO_HWID_NOT_SUPPORTED
}

# --- full response: every supported header present
_reset
gatygo_parse_headers "$FIXTURES/headers-full.txt" > "$tmp/full.env"
. "$tmp/full.env"
assert_eq "application/json" "$GATYGO_CONTENT_TYPE" "content-type"
assert_eq "Example VPN" "$GATYGO_PROFILE_TITLE" "profile-title is base64-decoded"
assert_eq "3" "$GATYGO_UPDATE_INTERVAL" "update interval in hours"
assert_eq "1024" "$GATYGO_USERINFO_UPLOAD" "userinfo upload"
assert_eq "123456789" "$GATYGO_USERINFO_DOWNLOAD" "userinfo download"
assert_eq "0" "$GATYGO_USERINFO_TOTAL" "userinfo total"
assert_eq "1767225600" "$GATYGO_USERINFO_EXPIRE" "userinfo expire"
assert_eq "0" "$(grep -c ANNOUNCE "$tmp/full.env")" "the panel's announce header is not read"
assert_eq "https://geo.example.com/geosite.dat" "$GATYGO_GEOSITE_URL" "Geositeurl from routing header"
assert_eq "https://geo.example.com/geoip.dat" "$GATYGO_GEOIP_URL" "Geoipurl from routing header"
assert_eq "0" "$GATYGO_HWID_MAX_DEVICES" "max-devices flag absent -> 0"
assert_eq "0" "$GATYGO_HWID_NOT_SUPPORTED" "not-supported flag absent -> 0"
assert_eq "11" "$(grep -c "^GATYGO_[A-Z_]*='" "$tmp/full.env")" "11 quoted assignments"
assert_eq "11" "$(wc -l < "$tmp/full.env" | tr -d ' ')" "and nothing else"

# --- minimal response: optional headers missing
_reset
gatygo_parse_headers "$FIXTURES/headers-minimal.txt" > "$tmp/min.env"
. "$tmp/min.env"
assert_eq "" "$GATYGO_PROFILE_TITLE" "missing title -> empty"
assert_eq "" "$GATYGO_UPDATE_INTERVAL" "missing interval -> empty"
assert_eq "" "$GATYGO_USERINFO_DOWNLOAD" "missing userinfo -> empty"
assert_eq "" "$GATYGO_GEOSITE_URL" "missing routing -> empty geosite url"
assert_eq "" "$GATYGO_GEOIP_URL" "missing routing -> empty geoip url"
assert_eq "0" "$GATYGO_HWID_MAX_DEVICES" "minimal: max-devices 0"

# --- device limit reached
_reset
gatygo_parse_headers "$FIXTURES/headers-max-devices.txt" > "$tmp/max.env"
. "$tmp/max.env"
assert_eq "1" "$GATYGO_HWID_MAX_DEVICES" "x-hwid-max-devices-reached: true -> 1"

# --- odd but legal input: mixed-case names, interval 0, undecodable routing, plain title
_reset
gatygo_parse_headers "$FIXTURES/headers-odd.txt" > "$tmp/odd.env"
. "$tmp/odd.env"
assert_eq "text/plain; charset=utf-8" "$GATYGO_CONTENT_TYPE" "header names are case-insensitive"
assert_eq "plain title" "$GATYGO_PROFILE_TITLE" "title without base64: prefix is used as is"
assert_eq "1" "$GATYGO_UPDATE_INTERVAL" "interval 0 is clamped to 1"
assert_eq "" "$GATYGO_GEOSITE_URL" "undecodable routing -> empty url, no crash"
assert_eq "" "$GATYGO_USERINFO_UPLOAD" "partial userinfo: missing field empty"
assert_eq "5" "$GATYGO_USERINFO_DOWNLOAD" "partial userinfo: present field parsed"
assert_eq "1" "$GATYGO_HWID_NOT_SUPPORTED" "X-HWID-Not-Supported: true -> 1"

# --- non-numeric interval and repeated header (last wins)
printf 'HTTP/2 200 \r\nprofile-update-interval: soon\r\nprofile-title: first\r\nprofile-title: second\r\n\r\n' > "$tmp/dup.txt"
_reset
gatygo_parse_headers "$tmp/dup.txt" > "$tmp/dup.env"
. "$tmp/dup.env"
assert_eq "" "$GATYGO_UPDATE_INTERVAL" "non-numeric interval -> empty"
assert_eq "second" "$GATYGO_PROFILE_TITLE" "repeated header: last value wins"

rm -rf "$tmp"
report
