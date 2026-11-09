#!/bin/sh
# Parse the subscription HTTP response headers into a sourceable headers.env.
#
#   gatygo_parse_headers RAW_HEADERS_FILE > headers.env
#
# RAW_HEADERS_FILE is what `curl -D FILE` writes (CRLF lines). Header names are matched
# case-insensitively; when a header repeats, the last value wins. Every value comes from
# the network, so each one is emitted single-quoted via gatygo_shquote: sourcing the result
# never executes anything from the response.
#
# Besides the subscription's own data the provider sends messages for the people at home (an
# announcement, a coloured one with a button, an expiry notice, links to its site and support)
# and may move the subscription (new-url, new-domain, fallback-url). Links meant for the page are
# kept only when they are http(s) addresses; the address headers are kept as sent: lib/suburl.sh
# checks them and logs why one is ignored.

. "${GATYGO_LIB:-/usr/lib/gatygo}/common.sh"

# _gatygo_hdr NAME FILE — print the trimmed value of the last header NAME, or nothing
_gatygo_hdr() {
    tr -d '\r' < "$2" | awk -v want="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" '
        {
            i = index($0, ":"); if (i == 0) next
            if (tolower(substr($0, 1, i - 1)) != want) next
            v = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
            last = v
        }
        END { if (last != "") print last }'
}

# _gatygo_b64text VALUE — decode VALUE when it carries the "base64:" prefix, else print as is
_gatygo_b64text() {
    case $1 in
        base64:*) printf '%s' "${1#base64:}" | jq -Rr '@base64d' 2>/dev/null ;;
        *) printf '%s' "$1" ;;
    esac
}

# _gatygo_userinfo KEY VALUE — integer field KEY of "upload=..; download=..; ..." or nothing
_gatygo_userinfo() {
    printf '%s' "$2" | tr ';' '\n' | sed -n "s/^[[:space:]]*$1=\([0-9]*\).*/\1/p" | head -n 1
}

# _gatygo_geo_url FIELD ROUTING — FIELD of the base64 JSON in "<scheme>://routing/add/<b64>" or nothing
_gatygo_geo_url() {
    case $2 in
        *://routing/add/*)
            printf '%s' "${2#*://routing/add/}" \
                | jq -Rr --arg f "$1" '@base64d | fromjson | .[$f] // empty' 2>/dev/null ;;
    esac
}

# _gatygo_flag NAME FILE — 1 if header NAME is literally "true", else 0
_gatygo_flag() {
    if [ "$(_gatygo_hdr "$1" "$2")" = true ]; then echo 1; else echo 0; fi
}

# _gatygo_on NAME FILE — 1 if header NAME is "true" or "1" in any case, else 0
_gatygo_on() {
    case $(_gatygo_hdr "$1" "$2" | tr 'A-Z' 'a-z') in
        true | 1) echo 1 ;;
        *) echo 0 ;;
    esac
}

# _gatygo_link NAME FILE — header NAME when it is an http(s) address, else nothing
_gatygo_link() {
    gatygo_http_url "$(_gatygo_hdr "$1" "$2")"
}

gatygo_parse_headers() {
    _gatygo_f=$1
    _gatygo_interval=$(_gatygo_hdr profile-update-interval "$_gatygo_f")
    case $_gatygo_interval in
        '' | *[!0-9]*) _gatygo_interval='' ;;
        *) [ "$_gatygo_interval" -ge 1 ] || _gatygo_interval=1 ;;
    esac
    _gatygo_ui=$(_gatygo_hdr subscription-userinfo "$_gatygo_f")
    _gatygo_routing=$(_gatygo_hdr routing "$_gatygo_f")
    # "0" switches the provider's coloured announcement off
    _gatygo_info=$(_gatygo_b64text "$(_gatygo_hdr sub-info-text "$_gatygo_f")")
    [ "$_gatygo_info" != 0 ] || _gatygo_info=''
    _gatygo_color=$(_gatygo_hdr sub-info-color "$_gatygo_f" | tr 'A-Z' 'a-z')
    case $_gatygo_color in red | green | blue) ;; *) _gatygo_color=blue ;; esac

    echo "GATYGO_CONTENT_TYPE=$(gatygo_shquote "$(_gatygo_hdr content-type "$_gatygo_f")")"
    echo "GATYGO_PROFILE_TITLE=$(gatygo_shquote "$(_gatygo_b64text "$(_gatygo_hdr profile-title "$_gatygo_f")")")"
    echo "GATYGO_UPDATE_INTERVAL=$(gatygo_shquote "$_gatygo_interval")"
    echo "GATYGO_USERINFO_UPLOAD=$(gatygo_shquote "$(_gatygo_userinfo upload "$_gatygo_ui")")"
    echo "GATYGO_USERINFO_DOWNLOAD=$(gatygo_shquote "$(_gatygo_userinfo download "$_gatygo_ui")")"
    echo "GATYGO_USERINFO_TOTAL=$(gatygo_shquote "$(_gatygo_userinfo total "$_gatygo_ui")")"
    echo "GATYGO_USERINFO_EXPIRE=$(gatygo_shquote "$(_gatygo_userinfo expire "$_gatygo_ui")")"
    echo "GATYGO_GEOSITE_URL=$(gatygo_shquote "$(_gatygo_geo_url Geositeurl "$_gatygo_routing")")"
    echo "GATYGO_GEOIP_URL=$(gatygo_shquote "$(_gatygo_geo_url Geoipurl "$_gatygo_routing")")"
    echo "GATYGO_HWID_MAX_DEVICES=$(gatygo_shquote "$(_gatygo_flag x-hwid-max-devices-reached "$_gatygo_f")")"
    echo "GATYGO_HWID_NOT_SUPPORTED=$(gatygo_shquote "$(_gatygo_flag x-hwid-not-supported "$_gatygo_f")")"
    echo "GATYGO_ANNOUNCE=$(gatygo_shquote "$(_gatygo_b64text "$(_gatygo_hdr announce "$_gatygo_f")")")"
    echo "GATYGO_SITE_URL=$(gatygo_shquote "$(_gatygo_link profile-web-page-url "$_gatygo_f")")"
    echo "GATYGO_SUPPORT_URL=$(gatygo_shquote "$(_gatygo_link support-url "$_gatygo_f")")"
    echo "GATYGO_INFO_TEXT=$(gatygo_shquote "$_gatygo_info")"
    echo "GATYGO_INFO_COLOR=$(gatygo_shquote "$_gatygo_color")"
    echo "GATYGO_INFO_BUTTON_TEXT=$(gatygo_shquote "$(_gatygo_b64text "$(_gatygo_hdr sub-info-button-text "$_gatygo_f")")")"
    echo "GATYGO_INFO_BUTTON_LINK=$(gatygo_shquote "$(_gatygo_link sub-info-button-link "$_gatygo_f")")"
    echo "GATYGO_EXPIRE_NOTICE=$(gatygo_shquote "$(_gatygo_on sub-expire "$_gatygo_f")")"
    echo "GATYGO_EXPIRE_LINK=$(gatygo_shquote "$(_gatygo_link sub-expire-button-link "$_gatygo_f")")"
    echo "GATYGO_NEW_URL=$(gatygo_shquote "$(_gatygo_hdr new-url "$_gatygo_f")")"
    echo "GATYGO_NEW_DOMAIN=$(gatygo_shquote "$(_gatygo_hdr new-domain "$_gatygo_f")")"
    echo "GATYGO_FALLBACK_URL=$(gatygo_shquote "$(_gatygo_hdr fallback-url "$_gatygo_f")")"
}
