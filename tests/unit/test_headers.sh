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
        GATYGO_NEW_URL GATYGO_NEW_DOMAIN GATYGO_FALLBACK_URL GATYGO_ROUTING_OFF
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
assert_eq "0" "$GATYGO_ROUTING_OFF" "routing add -> not off"
assert_eq "24" "$(grep -c "^GATYGO_[A-Z_]*='" "$tmp/full.env")" "24 quoted assignments"
assert_eq "24" "$(wc -l < "$tmp/full.env" | tr -d ' ')" "and nothing else"

# --- minimal response: optional headers missing
_reset
gatygo_parse_headers "$FIXTURES/headers-minimal.txt" > "$tmp/min.env"
. "$tmp/min.env"
assert_eq "" "$GATYGO_PROFILE_TITLE" "missing title -> empty"
assert_eq "" "$GATYGO_UPDATE_INTERVAL" "missing interval -> empty"
assert_eq "" "$GATYGO_USERINFO_DOWNLOAD" "missing userinfo -> empty"
assert_eq "" "$GATYGO_GEOSITE_URL" "missing routing -> empty geosite url"
assert_eq "" "$GATYGO_GEOIP_URL" "missing routing -> empty geoip url"
assert_eq "0" "$GATYGO_ROUTING_OFF" "missing routing -> not off"
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

# --- the routing header in every form a provider may send: <scheme>://routing/add|onadd/<b64>
# (any scheme, an empty one too), a bare <b64>, base64 with or without "=" and in the URL-safe
# alphabet; off switches the geo file links off; anything else gives no links
B=eyJHZW9zaXRldXJsIjoiaHR0cHM6Ly9nZW8uZXhhbXBsZS5jb20vZ2Vvc2l0ZS5kYXQiLCJHZW9pcHVybCI6Imh0dHBzOi8vZ2VvLmV4YW1wbGUuY29tL2dlb2lwLmRhdCJ9
# the geosite link ends in "?": its base64 holds a "/" and ends in "=="
Q=eyJHZW9zaXRldXJsIjoiaHR0cHM6Ly9nZW8uZXhhbXBsZS5jb20vZ2Vvc2l0ZS5kYXQ/IiwiR2VvaXB1cmwiOiJodHRwczovL2dlby5leGFtcGxlLmNvbS9nZW9pcC5kYXQifQ==
QS=$(printf '%s' "${Q%==}" | tr '/+' '_-')
GS=https://geo.example.com/geosite.dat GI=https://geo.example.com/geoip.dat
_routing() {
    printf 'HTTP/2 200 \r\nrouting: %s\r\n\r\n' "$1" > "$tmp/r.txt"
    gatygo_parse_headers "$tmp/r.txt" > "$tmp/r.env"
    ( _reset; . "$tmp/r.env"; printf '%s|%s|%s' "$GATYGO_GEOSITE_URL" "$GATYGO_GEOIP_URL" "$GATYGO_ROUTING_OFF" )
}
assert_eq "$GS|$GI|0" "$(_routing "app://routing/add/$B")" "routing add"
assert_eq "$GS|$GI|0" "$(_routing "app://routing/onadd/$B")" "routing onadd"
assert_eq "$GS|$GI|0" "$(_routing "://routing/add/$B")" "routing add with an empty scheme"
assert_eq "$GS|$GI|0" "$(_routing "://routing/onadd/$B")" "routing onadd with an empty scheme"
assert_eq "$GS|$GI|0" "$(_routing "$B")" "a bare base64 profile"
assert_eq "$GS?|$GI|0" "$(_routing "$Q")" "a bare profile with / and = in its base64"
assert_eq "$GS?|$GI|0" "$(_routing "${Q%==}")" "base64 without the = padding"
assert_eq "$GS?|$GI|0" "$(_routing "$QS")" "URL-safe base64 without padding"
assert_eq "$GS?|$GI|0" "$(_routing "app://routing/onadd/$QS")" "onadd with URL-safe base64"
assert_eq "||1" "$(_routing off)" "off"
assert_eq "||1" "$(_routing app://routing/off)" "<scheme>://routing/off"
assert_eq "||1" "$(_routing ://routing/off)" "://routing/off"
assert_eq "||0" "$(_routing 'app://routing/add/not-base64!')" "an undecodable profile: no links, not off"
assert_eq "||0" "$(_routing bm90IGpzb24=)" "base64 that is not JSON: no links, not off"
assert_eq "||0" "$(_routing "$(printf '%s' '{"Name":"x"}' | base64)")" "a profile without the link fields: no links"

rm -rf "$tmp"
report
