#!/bin/sh
# Geo files for xray: where the URLs come from, conditional download,
# staging so that new files are installed only after `xray run -test` accepted them.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"

_gatygo_is_url() { case $1 in http://?* | https://?*) return 0 ;; *) return 1 ;; esac; }

# gatygo_geo_urls HEADERS_ENV — print "GEOSITE_URL GEOIP_URL" from the routing header, else from the
# cache of the last header that carried them. exit 1 (nothing printed) when neither has them: geo
# files come only from the subscription.
gatygo_geo_urls() {
    _gatygo_gs='' _gatygo_gi=''
    if [ -f "$1" ]; then
        _gatygo_gs=$(_gatygo_env_get "$1" GATYGO_GEOSITE_URL)
        _gatygo_gi=$(_gatygo_env_get "$1" GATYGO_GEOIP_URL)
    fi
    if _gatygo_is_url "$_gatygo_gs" && _gatygo_is_url "$_gatygo_gi"; then
        {
            echo "GATYGO_GEOSITE_URL=$(gatygo_shquote "$_gatygo_gs")"
            echo "GATYGO_GEOIP_URL=$(gatygo_shquote "$_gatygo_gi")"
        } > "$GATYGO_STATE/geo-urls.env.tmp" && mv "$GATYGO_STATE/geo-urls.env.tmp" "$GATYGO_STATE/geo-urls.env"
    elif [ -f "$GATYGO_STATE/geo-urls.env" ]; then
        _gatygo_gs=$(_gatygo_env_get "$GATYGO_STATE/geo-urls.env" GATYGO_GEOSITE_URL)
        _gatygo_gi=$(_gatygo_env_get "$GATYGO_STATE/geo-urls.env" GATYGO_GEOIP_URL)
    else
        return 1
    fi
    printf '%s %s\n' "$_gatygo_gs" "$_gatygo_gi"
}

# gatygo_geo_due — exit 0 when geosite.dat/geoip.dat are missing or older than 24 hours
gatygo_geo_due() {
    for _gatygo_n in geosite.dat geoip.dat; do
        [ -f "$GATYGO_ASSETS/$_gatygo_n" ] || return 0
        [ $(( $(date +%s) - $(date -r "$GATYGO_ASSETS/$_gatygo_n" +%s) )) -lt 86400 ] || return 0
    done
    return 1
}

# gatygo_geo_record GEOSITE_URL GEOIP_URL — remember where the installed dats came from. Written
# by the update cycle once the files passed `xray run -test` and were installed.
gatygo_geo_record() {
    {
        echo "GATYGO_GEOSITE_URL=$(gatygo_shquote "$1")"
        echo "GATYGO_GEOIP_URL=$(gatygo_shquote "$2")"
    } > "$GATYGO_STATE/geo-source.env.tmp" && mv "$GATYGO_STATE/geo-source.env.tmp" "$GATYGO_STATE/geo-source.env"
}

# gatygo_geo_source_matches GEOSITE_URL GEOIP_URL — exit 0 when the installed dats are recorded as
# fetched from exactly these URLs. Only then is their mtime a valid If-Modified-Since: a file from
# anywhere else (feed package, another panel, a wiped state dir) with a newer mtime would get 304
# from the server and stay forever, failing `xray run -test` on every update.
gatygo_geo_source_matches() {
    [ -f "$GATYGO_STATE/geo-source.env" ] || return 1
    [ "$(_gatygo_env_get "$GATYGO_STATE/geo-source.env" GATYGO_GEOSITE_URL)" = "$1" ] \
        && [ "$(_gatygo_env_get "$GATYGO_STATE/geo-source.env" GATYGO_GEOIP_URL)" = "$2" ]
}

# gatygo_geo_fetch GEOSITE_URL GEOIP_URL STAGE_DIR — download changed files into STAGE_DIR.
# Conditional (If-Modified-Since = the installed file's mtime) only when the installed files are
# recorded as coming from these URLs; unconditional otherwise. Keeps the server's Last-Modified as
# mtime. Redirects are followed to https only (GitHub release URLs redirect; no credentials are
# sent here). exit 0 = at least one file staged, 3 = nothing new (304), 1 = error (STAGE_DIR emptied)
gatygo_geo_fetch() {
    _gatygo_stage=$3 _gatygo_staged=0 _gatygo_cond=0
    gatygo_geo_source_matches "$1" "$2" && _gatygo_cond=1
    for _gatygo_pair in "geosite.dat $1" "geoip.dat $2"; do
        _gatygo_n=${_gatygo_pair%% *} _gatygo_u=${_gatygo_pair#* }
        _gatygo_cur=$GATYGO_ASSETS/$_gatygo_n
        if [ "$_gatygo_cond" = 1 ] && [ -f "$_gatygo_cur" ]; then
            _gatygo_code=$(curl -sS --max-time 60 --retry 2 --retry-delay 5 --proto '=http,https' \
                -L --max-redirs 3 --proto-redir '=https' -R -z "$_gatygo_cur" \
                -o "$_gatygo_stage/$_gatygo_n" -w '%{http_code}' "$_gatygo_u" 2>/dev/null)
        else
            _gatygo_code=$(curl -sS --max-time 60 --retry 2 --retry-delay 5 --proto '=http,https' \
                -L --max-redirs 3 --proto-redir '=https' -R \
                -o "$_gatygo_stage/$_gatygo_n" -w '%{http_code}' "$_gatygo_u" 2>/dev/null)
        fi
        case $_gatygo_code in
            200)
                [ -s "$_gatygo_stage/$_gatygo_n" ] || { gatygo_log error "geo: empty $_gatygo_n"; rm -f "$_gatygo_stage"/*.dat; return 1; }
                _gatygo_staged=1 ;;
            304) rm -f "$_gatygo_stage/$_gatygo_n" ;;
            *)
                gatygo_log error "geo: download of $_gatygo_n failed (HTTP ${_gatygo_code:-none})"
                rm -f "$_gatygo_stage"/*.dat; return 1 ;;
        esac
    done
    [ "$_gatygo_staged" = 1 ] && return 0 || return 3
}
