#!/bin/sh
. "$(dirname "$0")/../lib.sh"
. "$GATYGO_LIB/headers.sh"
tmp=$(mktemp -d)

# Unset every output variable so a missing line would be caught as empty.
_reset() {
    unset GATYGO_CONTENT_TYPE GATYGO_PROFILE_TITLE GATYGO_UPDATE_INTERVAL \
        GATYGO_USERINFO_UPLOAD GATYGO_USERINFO_DOWNLOAD GATYGO_USERINFO_TOTAL GATYGO_USERINFO_EXPIRE \
        GATYGO_GEOSITE_URL GATYGO_GEOIP_URL GATYGO_HWID_MAX_DEVICES GATYGO_HWID_NOT_SUPPORTED \
        GATYGO_ANNOUNCE GATYGO_SITE_URL GATYGO_SUPPORT_URL GATYGO_INFO_TEXT GATYGO_INFO_COLOR \
        GATYGO_INFO_BUTTON_TEXT GATYGO_INFO_BUTTON_LINK GATYGO_EXPIRE_NOTICE GATYGO_EXPIRE_LINK \
        GATYGO_NEW_URL GATYGO_NEW_DOMAIN GATYGO_FALLBACK_URL
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
assert_eq "https://geo.example.com/geosite.dat" "$GATYGO_GEOSITE_URL" "Geositeurl from routing header"
assert_eq "https://geo.example.com/geoip.dat" "$GATYGO_GEOIP_URL" "Geoipurl from routing header"
assert_eq "0" "$GATYGO_HWID_MAX_DEVICES" "max-devices flag absent -> 0"
assert_eq "0" "$GATYGO_HWID_NOT_SUPPORTED" "not-supported flag absent -> 0"
assert_eq "Planned maintenance — use code 'GO' ✓" "$GATYGO_ANNOUNCE" "announce is base64-decoded"
assert_eq "https://example.com" "$GATYGO_SITE_URL" "profile-web-page-url"
assert_eq "https://support.example.com/chat" "$GATYGO_SUPPORT_URL" "support-url"
assert_eq "Japan is in the list now. Press Update now." "$GATYGO_INFO_TEXT" "sub-info-text"
assert_eq "green" "$GATYGO_INFO_COLOR" "sub-info-color"
assert_eq "More" "$GATYGO_INFO_BUTTON_TEXT" "sub-info-button-text"
assert_eq "https://example.com/news" "$GATYGO_INFO_BUTTON_LINK" "sub-info-button-link"
assert_eq "1" "$GATYGO_EXPIRE_NOTICE" "sub-expire: 1"
assert_eq "https://example.com/renew" "$GATYGO_EXPIRE_LINK" "sub-expire-button-link"
assert_eq "https://sub.example.net/s/abc" "$GATYGO_NEW_URL" "new-url as sent"
assert_eq "sub.example.org" "$GATYGO_NEW_DOMAIN" "new-domain as sent"
assert_eq "https://backup.example.com/s/abc" "$GATYGO_FALLBACK_URL" "fallback-url as sent"
assert_eq "23" "$(grep -c "^GATYGO_[A-Z_]*='" "$tmp/full.env")" "23 quoted assignments"
assert_eq "23" "$(wc -l < "$tmp/full.env" | tr -d ' ')" "and nothing else"

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
assert_eq "||||||||||" "$GATYGO_ANNOUNCE|$GATYGO_SITE_URL|$GATYGO_SUPPORT_URL|$GATYGO_INFO_TEXT|$GATYGO_INFO_BUTTON_TEXT|$GATYGO_INFO_BUTTON_LINK|$GATYGO_EXPIRE_LINK|$GATYGO_NEW_URL|$GATYGO_NEW_DOMAIN|$GATYGO_FALLBACK_URL|" "minimal: no messages, links or addresses"
assert_eq "blue 0" "$GATYGO_INFO_COLOR $GATYGO_EXPIRE_NOTICE" "minimal: the colour defaults to blue, no expiry notice"

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

# --- the provider's values that are off, odd or unsafe for the page
printf 'HTTP/2 200 \r\nsub-info-text: 0\r\nsub-info-color: Purple\r\nsub-expire: TRUE\r\nsupport-url: javascript:alert(1)\r\nprofile-web-page-url: tg://resolve?domain=x\r\nsub-info-button-link: https://exa mple.com\r\nsub-expire-button-link: ftp://example.com/renew\r\nnew-domain:  sub.example.org  \r\n\r\n' > "$tmp/odd2.txt"
_reset
gatygo_parse_headers "$tmp/odd2.txt" > "$tmp/odd2.env"
. "$tmp/odd2.env"
assert_eq "" "$GATYGO_INFO_TEXT" "sub-info-text: 0 -> no announcement"
assert_eq "blue" "$GATYGO_INFO_COLOR" "an unknown colour -> blue"
assert_eq "1" "$GATYGO_EXPIRE_NOTICE" "sub-expire: TRUE -> 1"
assert_eq "" "$GATYGO_SUPPORT_URL" "a javascript: link is dropped"
assert_eq "" "$GATYGO_SITE_URL" "a tg: link is dropped"
assert_eq "" "$GATYGO_INFO_BUTTON_LINK" "a link with a space is dropped"
assert_eq "" "$GATYGO_EXPIRE_LINK" "an ftp: link is dropped"
assert_eq "sub.example.org" "$GATYGO_NEW_DOMAIN" "new-domain is trimmed"

rm -rf "$tmp"
report
