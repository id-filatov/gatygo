#!/bin/sh
# Geo files for xray: where the URLs come from, conditional download,
# staging so that new files are installed only after `xray run -test` accepted them.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/service.sh"

_gatygo_is_url() { case $1 in http://?* | https://?*) return 0 ;; *) return 1 ;; esac; }

# gatygo_geo_named FILE — exit 0 when FILE (a subscription body or a config) names geo data
gatygo_geo_named() { grep -qE '"(geosite|geoip):' "$1" 2>/dev/null || return 1; }

# gatygo_geo_urls HEADERS_ENV [SUB_BODY] — print "GEOSITE_URL GEOIP_URL" from the routing header,
# else from the cache of the last header that carried them, else, when SUB_BODY names geo data
# (in any profile: `gatygo select` may pick another one) and the provider's own files are not in
# place, the default files (Loyalsoldier's): the provider's always win. exit 1 (nothing printed)
# when there are none. The default URLs are never cached. A provider that switched routing off has
# no geo files to give: the cache goes too, and the files it gave before stay.
gatygo_geo_urls() {
    _gatygo_gs='' _gatygo_gi=''
    if [ -f "$1" ] && [ "$(_gatygo_env_get "$1" GATYGO_ROUTING_OFF)" = 1 ]; then
        rm -f "$GATYGO_STATE/geo-urls.env"
    elif [ -f "$1" ]; then
        _gatygo_gs=$(_gatygo_env_get "$1" GATYGO_GEOSITE_URL)
        _gatygo_gi=$(_gatygo_env_get "$1" GATYGO_GEOIP_URL)
    fi
    if _gatygo_is_url "$_gatygo_gs" && _gatygo_is_url "$_gatygo_gi"; then
        # written only when they change: the router's flash is not written on every update
        _gatygo_gnew=$(printf 'GATYGO_GEOSITE_URL=%s\nGATYGO_GEOIP_URL=%s' "$(gatygo_shquote "$_gatygo_gs")" "$(gatygo_shquote "$_gatygo_gi")")
        [ "$(cat "$GATYGO_STATE/geo-urls.env" 2>/dev/null)" = "$_gatygo_gnew" ] \
            || { printf '%s\n' "$_gatygo_gnew" > "$GATYGO_STATE/geo-urls.env.tmp" \
                && mv "$GATYGO_STATE/geo-urls.env.tmp" "$GATYGO_STATE/geo-urls.env"; }
    elif [ -f "$GATYGO_STATE/geo-urls.env" ]; then
        _gatygo_gs=$(_gatygo_env_get "$GATYGO_STATE/geo-urls.env" GATYGO_GEOSITE_URL)
        _gatygo_gi=$(_gatygo_env_get "$GATYGO_STATE/geo-urls.env" GATYGO_GEOIP_URL)
    elif [ -n "$2" ] && gatygo_geo_named "$2" && ! gatygo_geo_provider_kept; then
        _gatygo_gs=$GATYGO_GEO_DEFAULT_BASE/geosite.dat _gatygo_gi=$GATYGO_GEO_DEFAULT_BASE/geoip.dat
    else
        return 1
    fi
    printf '%s %s\n' "$_gatygo_gs" "$_gatygo_gi"
}

# gatygo_geo_is_default GEOSITE_URL — exit 0 when it is the default geosite URL
gatygo_geo_is_default() { [ "$1" = "$GATYGO_GEO_DEFAULT_BASE/geosite.dat" ]; }

# gatygo_geo_source_default — exit 0 when the installed dats are recorded as the default files
# (a mark of its own: a later release may take them from elsewhere)
gatygo_geo_source_default() {
    [ "$(_gatygo_env_get "$GATYGO_STATE/geo-source.env" GATYGO_GEO_DEFAULT)" = 1 ]
}

# gatygo_geo_provider_kept — exit 0 when both dats in place are the provider's: recorded as
# downloaded from its URLs, files of their own (not links to the default ones)
gatygo_geo_provider_kept() {
    [ -f "$GATYGO_STATE/geo-source.env" ] && ! gatygo_geo_source_default || return 1
    for _gatygo_n in geosite.dat geoip.dat; do
        [ -s "$GATYGO_ASSETS/$_gatygo_n" ] && [ ! -L "$GATYGO_ASSETS/$_gatygo_n" ] || return 1
    done
}

# gatygo_geo_due — exit 0 when geosite.dat/geoip.dat are missing or older than 24 hours
gatygo_geo_due() {
    for _gatygo_n in geosite.dat geoip.dat; do
        [ -f "$GATYGO_ASSETS/$_gatygo_n" ] || return 0
        [ $(( $(date +%s) - $(date -r "$GATYGO_ASSETS/$_gatygo_n" +%s) )) -lt 86400 ] || return 0
    done
    return 1
}

# gatygo_geo_missing CONFIG — exit 0 when CONFIG names geo data and a dat file is not there: the
# state dir with the config survives a sysupgrade, the dats do not, and xray would only crash.
gatygo_geo_missing() {
    for _gatygo_n in geosite geoip; do
        grep -q "\"$_gatygo_n:" "$1" 2>/dev/null || continue
        [ -s "$GATYGO_ASSETS/$_gatygo_n.dat" ] || return 0
    done
    return 1
}

# gatygo_geo_record GEOSITE_URL GEOIP_URL [default] — remember where the installed dats came from,
# and with `default` that they are the default ones. Written by the update cycle once the files
# passed `xray run -test` and were installed.
gatygo_geo_record() {
    _gatygo_grec=$(
        echo "GATYGO_GEOSITE_URL=$(gatygo_shquote "$1")"
        echo "GATYGO_GEOIP_URL=$(gatygo_shquote "$2")"
        [ "${3:-}" != default ] || echo "GATYGO_GEO_DEFAULT='1'"
    )
    # written only when it changes: the router's flash is not written on every check
    [ "$(cat "$GATYGO_STATE/geo-source.env" 2>/dev/null)" = "$_gatygo_grec" ] && return 0
    printf '%s\n' "$_gatygo_grec" > "$GATYGO_STATE/geo-source.env.tmp" && mv "$GATYGO_STATE/geo-source.env.tmp" "$GATYGO_STATE/geo-source.env"
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

# gatygo_geo_install_default STAGE — install the default dats staged in STAGE: into
# $GATYGO_GEO_TMP (RAM; moved, not copied: 28 MB), $GATYGO_ASSETS/<name> becomes a link to each, so
# xray finds them where it always looks and the flash is never written with them. Prints
# changed|unchanged.
gatygo_geo_install_default() {
    _gatygo_dch=0
    mkdir -p "$GATYGO_GEO_TMP" "$GATYGO_ASSETS"
    for _gatygo_n in geosite.dat geoip.dat; do
        _gatygo_ram=$GATYGO_GEO_TMP/$_gatygo_n
        if [ -f "$1/$_gatygo_n" ]; then
            if [ ! -f "$_gatygo_ram" ] || [ "$(sha256sum < "$1/$_gatygo_n")" != "$(sha256sum < "$_gatygo_ram")" ]; then
                chmod 644 "$1/$_gatygo_n" && mv -f "$1/$_gatygo_n" "$_gatygo_ram" && _gatygo_dch=1
            else
                touch "$_gatygo_ram"
            fi
        fi
        if [ -f "$_gatygo_ram" ] && [ "$(readlink "$GATYGO_ASSETS/$_gatygo_n" 2>/dev/null)" != "$_gatygo_ram" ]; then
            ln -sf "$_gatygo_ram" "$GATYGO_ASSETS/$_gatygo_n.tmp" \
                && mv -f "$GATYGO_ASSETS/$_gatygo_n.tmp" "$GATYGO_ASSETS/$_gatygo_n" && _gatygo_dch=1
        fi
    done
    [ "$_gatygo_dch" = 1 ] && echo changed || echo unchanged
}

# gatygo_geo_drop_default — the default dats go: the links to them, the files in RAM, their record
gatygo_geo_drop_default() {
    for _gatygo_n in geosite.dat geoip.dat; do
        if [ "$(readlink "$GATYGO_ASSETS/$_gatygo_n" 2>/dev/null)" = "$GATYGO_GEO_TMP/$_gatygo_n" ]; then
            rm -f "$GATYGO_ASSETS/$_gatygo_n"
        fi
        rm -f "$GATYGO_GEO_TMP/$_gatygo_n"
    done
    rm -f "$GATYGO_STATE/geo-source.env"
    gatygo_log info "geo: the subscription names no geo rules any more; Loyalsoldier's geo files removed"
}

# gatygo_geo_failed_recently BODY_SHA GEOSITE_URL — exit 0 when a config of this subscription body
# failed the test with default dats freshly downloaded from there less than a day ago
# ($GATYGO_RUN/geo-failed)
gatygo_geo_failed_recently() {
    [ "$(cat "$GATYGO_RUN/geo-failed" 2>/dev/null)" = "$1 $2" ] || return 1
    [ $(( $(date +%s) - $(date -r "$GATYGO_RUN/geo-failed" +%s) )) -lt 86400 ]
}

# gatygo_geo_fetch GEOSITE_URL GEOIP_URL STAGE_DIR — download changed files into STAGE_DIR.
# Conditional (If-Modified-Since = the installed file's mtime) only when the installed files are
# recorded as coming from these URLs; unconditional otherwise. Keeps the server's Last-Modified as
# mtime. Redirects are followed to https only (GitHub release URLs redirect; no credentials are
# sent here). The default files are 16 MB: a slow link gets 5 minutes, and only a stalled one (under
# 1 KB/s for a minute) is cut off early. A transfer cut short still reports 200: curl's own exit
# status decides. exit 0 = at least one file staged, 3 = nothing new (304), 1 = error (STAGE_DIR emptied)
gatygo_geo_fetch() {
    _gatygo_stage=$3 _gatygo_staged=0 _gatygo_cond=0
    gatygo_geo_source_matches "$1" "$2" && _gatygo_cond=1
    for _gatygo_pair in "geosite.dat $1" "geoip.dat $2"; do
        _gatygo_n=${_gatygo_pair%% *} _gatygo_u=${_gatygo_pair#* }
        _gatygo_cur=$GATYGO_ASSETS/$_gatygo_n
        _gatygo_crc=0
        if [ "$_gatygo_cond" = 1 ] && [ -f "$_gatygo_cur" ]; then
            _gatygo_code=$(curl -sS --connect-timeout 20 --max-time 300 --speed-limit 1024 --speed-time 60 \
                --retry 2 --retry-delay 5 --proto '=http,https' \
                -L --max-redirs 3 --proto-redir '=https' -R -z "$_gatygo_cur" \
                -o "$_gatygo_stage/$_gatygo_n" -w '%{http_code}' "$_gatygo_u" 2>/dev/null) || _gatygo_crc=$?
        else
            _gatygo_code=$(curl -sS --connect-timeout 20 --max-time 300 --speed-limit 1024 --speed-time 60 \
                --retry 2 --retry-delay 5 --proto '=http,https' \
                -L --max-redirs 3 --proto-redir '=https' -R \
                -o "$_gatygo_stage/$_gatygo_n" -w '%{http_code}' "$_gatygo_u" 2>/dev/null) || _gatygo_crc=$?
        fi
        if [ "$_gatygo_crc" != 0 ]; then
            gatygo_log error "geo: download of $_gatygo_n failed (HTTP ${_gatygo_code:-none}, curl exit $_gatygo_crc)"
            rm -f "$_gatygo_stage"/*.dat; return 1
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

# gatygo_geo_restore — after a reboot (RAM is empty): the default dats come again, the subscription
# is not asked (with updates only by hand a reboot downloads nothing else). They are downloaded
# outside any lock, tested by xray against the installed config (a new release may lack a tag it
# names), and put in place under the update lock, only when they are still recorded as the
# default ones (an update or `gatygo forget` may have come meanwhile). exit 0 they are in place,
# 1 they could not be downloaded, 2 the installed dats are not the default ones (nothing done),
# 3 an update runs (try again later), 4 they do not fit the config; 1, 3, 4: nothing touched.
gatygo_geo_restore() {
    gatygo_geo_source_default || return 2
    _gatygo_rs=$(mktemp -d) || return 1
    gatygo_geo_fetch "$GATYGO_GEO_DEFAULT_BASE/geosite.dat" "$GATYGO_GEO_DEFAULT_BASE/geoip.dat" "$_gatygo_rs"
    _gatygo_rf=$?
    if [ "$_gatygo_rf" -eq 1 ]; then rm -rf "$_gatygo_rs"; return 1; fi
    if [ "$_gatygo_rf" -eq 0 ] && [ -s "$GATYGO_STATE/xray.json" ]; then
        mkdir "$_gatygo_rs/test"
        for _gatygo_n in geosite.dat geoip.dat; do
            if [ -f "$_gatygo_rs/$_gatygo_n" ]; then ln -f "$_gatygo_rs/$_gatygo_n" "$_gatygo_rs/test/$_gatygo_n" 2>/dev/null || cp -p "$_gatygo_rs/$_gatygo_n" "$_gatygo_rs/test/$_gatygo_n"
            else ln -s "$GATYGO_ASSETS/$_gatygo_n" "$_gatygo_rs/test/$_gatygo_n"
            fi
        done
        if ! _gatygo_out=$(XRAY_LOCATION_ASSET=$_gatygo_rs/test "$GATYGO_XRAY" run -test -c "$GATYGO_STATE/xray.json" 2>&1); then
            gatygo_log error "geo: Loyalsoldier's geo files do not fit the config: $(printf '%s' "$_gatygo_out" | grep -v -e '^Xray ' -e '^A unified' | tail -n 2 | tr '\n' ' ')"
            rm -rf "$_gatygo_rs"; return 4
        fi
    fi
    if ! gatygo_update_lock; then rm -rf "$_gatygo_rs"; return 3; fi
    _gatygo_rr=2
    if gatygo_geo_source_default; then
        gatygo_geo_install_default "$_gatygo_rs" >/dev/null
        _gatygo_rr=0
    fi
    gatygo_update_unlock
    rm -rf "$_gatygo_rs"
    [ "$_gatygo_rr" = 0 ] || return 2
    [ -s "$GATYGO_ASSETS/geosite.dat" ] && [ -s "$GATYGO_ASSETS/geoip.dat" ]
}

# _gatygo_geo_wait STATE [NEXT] — tell the page the VPN waits for the default dats
# ($GATYGO_RUN/geo-wait): downloading, failed with the time of the next try, or unfit (they do not
# fit the config: no more tries); and whether the home network is closed meanwhile
# (on_crash=block, the init script), as the settings are now
_gatygo_geo_wait() {
    _gatygo_blk=1; [ "$(gatygo_cfg on_crash block)" != direct ] || _gatygo_blk=0
    printf "GATYGO_GEO_WAIT='%s'\nGATYGO_GEO_NEXT='%s'\nGATYGO_GEO_BLOCK='%s'\n" "$1" "${2:-}" "$_gatygo_blk" \
        > "$GATYGO_RUN/geo-wait.tmp" && mv "$GATYGO_RUN/geo-wait.tmp" "$GATYGO_RUN/geo-wait"
}

# gatygo_geo_waiting — exit 0 when the VPN waits for the default dats: their download runs, or
# they did not fit the config (until a Start or a Stop)
gatygo_geo_waiting() {
    [ -f "$GATYGO_RUN/geo-wait" ] || return 1
    [ "$(_gatygo_env_get "$GATYGO_RUN/geo-wait" GATYGO_GEO_WAIT)" != unfit ] || return 0
    gatygo_geo_restoring
}

# gatygo_geo_restoring — exit 0 when the download of the default dats runs in the background
gatygo_geo_restoring() {
    _gatygo_rp=$(cat "$GATYGO_RUN/geo-retry" 2>/dev/null)
    [ -n "$_gatygo_rp" ] && kill -0 "$_gatygo_rp" 2>/dev/null
}

# _gatygo_geo_backoff SECONDS — the pause after SECONDS when no VPN waits: twice as long, an hour
# at most
_gatygo_geo_backoff() {
    _gatygo_b=$(($1 * 2))
    [ "$_gatygo_b" -le 3600 ] || _gatygo_b=3600
    echo "$_gatygo_b"
}

# gatygo_geo_restore_later [start] — gatygo_geo_restore in the background until the dats are in
# place, they are no longer the default ones, they do not fit the config, or the VPN is stopped by
# hand or switched off. With `start` the VPN waits for them ($GATYGO_RUN/geo-start, a running
# download takes it up too): a try every minute (GATYGO_GEO_RETRY_DELAY seconds), the page is
# told ($GATYGO_RUN/geo-wait), and the service is started once they are there. Without it the
# pauses grow (_gatygo_geo_backoff). Only the first failed try is logged. At most one runs
# ($GATYGO_RUN/geo-retry: its pid). It lets go of procd's lock (rc.common holds it on fd 1000):
# kept, it would hold up every stop until then.
gatygo_geo_restore_later() {
    mkdir -p "$GATYGO_RUN"
    _gatygo_alive=0
    _gatygo_rp=$(cat "$GATYGO_RUN/geo-retry" 2>/dev/null)
    [ -n "$_gatygo_rp" ] && kill -0 "$_gatygo_rp" 2>/dev/null && _gatygo_alive=1
    if [ "${1:-}" = start ]; then
        : > "$GATYGO_RUN/geo-start"
        # the page at once as the settings are now; a running download keeps its state
        if [ "$_gatygo_alive" = 1 ] && [ -f "$GATYGO_RUN/geo-wait" ]; then
            _gatygo_geo_wait "$(_gatygo_env_get "$GATYGO_RUN/geo-wait" GATYGO_GEO_WAIT)" "$(_gatygo_env_get "$GATYGO_RUN/geo-wait" GATYGO_GEO_NEXT)"
        else
            _gatygo_geo_wait downloading
        fi
    fi
    [ "$_gatygo_alive" = 0 ] || return 0
    (
        # the update lock it takes names this subshell, not the shell that started it
        read -r GATYGO_LOCK_PID _gatygo_x < /proc/self/stat
        _gatygo_base=${GATYGO_GEO_RETRY_DELAY:-60}
        _gatygo_rr='' _gatygo_failed=0 _gatygo_d=$_gatygo_base
        while :; do
            while [ ! -f "$GATYGO_RUN/stopped" ] && [ "$(gatygo_cfg enabled 0)" = 1 ]; do
                gatygo_geo_restore
                _gatygo_rr=$?
                case $_gatygo_rr in 0 | 2 | 4) break ;; esac
                if [ "$_gatygo_rr" = 1 ] && [ "$_gatygo_failed" = 0 ]; then
                    if [ -f "$GATYGO_RUN/geo-start" ]; then
                        gatygo_log error "geo: Loyalsoldier's geo files could not be downloaded; trying again every minute"
                    else
                        gatygo_log error "geo: Loyalsoldier's geo files could not be downloaded; trying again later"
                    fi
                    _gatygo_failed=1 GATYGO_LOG_QUIET=1
                fi
                if [ -f "$GATYGO_RUN/geo-start" ]; then
                    _gatygo_d=$_gatygo_base
                    # an update held its lock: the files came, they wait for it to end
                    if [ "$_gatygo_rr" = 3 ]; then _gatygo_geo_wait downloading
                    else _gatygo_geo_wait failed $(($(date +%s) + _gatygo_d))
                    fi
                fi
                sleep "$_gatygo_d"
                [ -f "$GATYGO_RUN/geo-start" ] || _gatygo_d=$(_gatygo_geo_backoff "$_gatygo_d")
            done
            case $_gatygo_rr in 0 | 2 | 4) break ;; esac
            # stopped or switched off; a Start that came while it was leaving saw it still running
            # and started none of its own: then it goes on
            rm -f "$GATYGO_RUN/geo-retry"
            if [ ! -f "$GATYGO_RUN/stopped" ] && [ -f "$GATYGO_RUN/geo-start" ] && [ "$(gatygo_cfg enabled 0)" = 1 ]; then
                echo "$GATYGO_LOCK_PID" > "$GATYGO_RUN/geo-retry"
                continue
            fi
            break
        done
        GATYGO_LOG_QUIET=''
        [ "$_gatygo_rr" != 0 ] || gatygo_log info "geo: Loyalsoldier's geo files are in place again"
        _gatygo_st=0; [ ! -f "$GATYGO_RUN/geo-start" ] || _gatygo_st=1
        # files that do not fit: the VPN keeps waiting with them refused, the page told why
        if [ "$_gatygo_rr" = 4 ] && [ "$_gatygo_st" = 1 ]; then _gatygo_geo_wait unfit
        else rm -f "$GATYGO_RUN/geo-wait"
        fi
        rm -f "$GATYGO_RUN/geo-start" "$GATYGO_RUN/geo-retry"
        case $_gatygo_rr in
            0 | 2) [ "$_gatygo_st" = 0 ] || [ -f "$GATYGO_RUN/stopped" ] || GATYGO_GEO_START=1 "${GATYGO_INIT:-/etc/init.d/gatygo}" start ;;
        esac
    ) 1000>&- >/dev/null 2>&1 &
    echo "$!" > "$GATYGO_RUN/geo-retry"
}
