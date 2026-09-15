#!/bin/sh
# The update cycle: fetch → validate → geo → select → transform → test → swap,
# plus the pieces the CLI reuses for `select`.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/hwid.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/headers.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/subscription.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/transform.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/fetch.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/geo.sh"

GATYGO_INIT=${GATYGO_INIT:-/etc/init.d/gatygo}

# gatygo_result RESULT MESSAGE [PROFILE] [RESTARTED] — record the outcome for the UI and log it
gatygo_result() {
    mkdir -p "$GATYGO_RUN"
    {
        echo "RESULT=$(gatygo_shquote "$1")"
        echo "TIME=$(date +%s)"
        echo "MESSAGE=$(gatygo_shquote "$2")"
        echo "PROFILE=$(gatygo_shquote "${3:-}")"
        echo "RESTARTED=$(gatygo_shquote "${4:-0}")"
    } > "$GATYGO_RUN/last-update.env.tmp" && mv "$GATYGO_RUN/last-update.env.tmp" "$GATYGO_RUN/last-update.env"
    case $1 in
        error) gatygo_log error "$2" ;;
        warning) gatygo_log warn "$2" ;;
        *) gatygo_log info "$2" ;;
    esac
}

# gatygo_xray_test CONFIG ASSET_DIR — `xray run -test`; on failure log the tail of xray's output
gatygo_xray_test() {
    _gatygo_out=$(XRAY_LOCATION_ASSET=$2 xray run -test -c "$1" 2>&1) && return 0
    gatygo_log error "xray -test failed: $(printf '%s' "$_gatygo_out" | grep -v -e '^Xray ' -e '^A unified' | tail -n 3 | tr '\n' ' ')"
    return 1
}

# gatygo_stage_assets STAGE TESTDIR — TESTDIR gets the staged dats plus the current ones for the rest
gatygo_stage_assets() {
    for _gatygo_n in geosite.dat geoip.dat; do
        if [ -f "$1/$_gatygo_n" ]; then cp -p "$1/$_gatygo_n" "$2/$_gatygo_n"
        elif [ -f "$GATYGO_ASSETS/$_gatygo_n" ]; then cp -p "$GATYGO_ASSETS/$_gatygo_n" "$2/$_gatygo_n"
        fi
    done
}

# _gatygo_install SRC DST MODE — copy then rename inside DST's directory (atomic on the same fs)
_gatygo_install() {
    cp -p "$1" "$2.tmp" && chmod "$3" "$2.tmp" && mv "$2.tmp" "$2"
}

# gatygo_swap NEW_XRAY STAGE — install the config and any staged dat that differs; prints changed|unchanged
gatygo_swap() {
    _gatygo_changed=0
    if [ ! -f "$GATYGO_STATE/xray.json" ] || [ "$(sha256sum < "$1")" != "$(sha256sum < "$GATYGO_STATE/xray.json")" ]; then
        _gatygo_install "$1" "$GATYGO_STATE/xray.json" 600 && _gatygo_changed=1
    fi
    mkdir -p "$GATYGO_ASSETS"
    for _gatygo_n in geosite.dat geoip.dat; do
        [ -f "$2/$_gatygo_n" ] || continue
        if [ ! -f "$GATYGO_ASSETS/$_gatygo_n" ] || [ "$(sha256sum < "$2/$_gatygo_n")" != "$(sha256sum < "$GATYGO_ASSETS/$_gatygo_n")" ]; then
            _gatygo_install "$2/$_gatygo_n" "$GATYGO_ASSETS/$_gatygo_n" 644 && _gatygo_changed=1
        else
            touch "$GATYGO_ASSETS/$_gatygo_n"
        fi
    done
    [ "$_gatygo_changed" = 1 ] && echo changed || echo unchanged
}

# gatygo_apply_profile SUB_JSON STAGE — select the UCI profile, transform, test with the dats that
# would be installed, swap. Prints the profile used. exit 0, 3 = fallback profile used, 1 = failed.
# The swap outcome (changed|unchanged) goes to GATYGO_SWAP_RESULT and to $GATYGO_RUN/swap-result,
# because callers usually run this inside a command substitution.
gatygo_apply_profile() {
    _gatygo_t=$(mktemp -d)
    _gatygo_prof=$(gatygo_sub_select "$1" "$GATYGO_PROFILE" "$_gatygo_t/selected.json")
    _gatygo_sel=$?
    if [ "$_gatygo_sel" -eq 1 ]; then rm -rf "$_gatygo_t"; return 1; fi
    if ! gatygo_transform "$_gatygo_t/selected.json" "$_gatygo_t/xray.json" "$GATYGO_TPROXY_PORT" "$GATYGO_DNS_PORT" \
            "$GATYGO_MARK_DEC" "$GATYGO_LOGLEVEL" "$GATYGO_LOG"; then
        rm -rf "$_gatygo_t"; return 1
    fi
    mkdir -p "$_gatygo_t/assets"
    gatygo_stage_assets "$2" "$_gatygo_t/assets"
    if ! gatygo_xray_test "$_gatygo_t/xray.json" "$_gatygo_t/assets"; then rm -rf "$_gatygo_t"; return 1; fi
    GATYGO_SWAP_RESULT=$(gatygo_swap "$_gatygo_t/xray.json" "$2")
    mkdir -p "$GATYGO_RUN" && printf '%s\n' "$GATYGO_SWAP_RESULT" > "$GATYGO_RUN/swap-result"
    rm -rf "$_gatygo_t"
    printf '%s\n' "$_gatygo_prof"
    return "$_gatygo_sel"
}

# _gatygo_reload — re-submit the procd instance when the service runs: procd restarts xray only
# if xray.json or a geo file changed. `start` is used on purpose: `reload` is the settings-changed
# hook of the init script and would kick another update.
_gatygo_reload() {
    [ -x "$GATYGO_INIT" ] || return 0
    "$GATYGO_INIT" running >/dev/null 2>&1 || return 0
    "$GATYGO_INIT" start >/dev/null 2>&1
}

# gatygo_update — exit 0 on ok/warning, 1 on error (the current config is never touched then)
gatygo_update() {
    gatygo_load_config
    if [ -z "$GATYGO_SUB_URL" ]; then gatygo_result error "subscription URL is not configured"; return 1; fi
    mkdir -p "$GATYGO_STATE" && chmod 700 "$GATYGO_STATE"
    _gatygo_hwid=''
    [ "$GATYGO_SEND_HWID" = 1 ] && _gatygo_hwid=$(gatygo_hwid_ensure)
    _gatygo_w=$(mktemp -d)
    mkdir -p "$_gatygo_w/geo"

    # 1. fetch
    _gatygo_code=$(gatygo_fetch "$GATYGO_SUB_URL" "$GATYGO_USER_AGENT" "$_gatygo_hwid" "$_gatygo_w/body" "$_gatygo_w/hdr")
    if [ $? -ne 0 ]; then
        gatygo_result error "subscription download failed (HTTP ${_gatygo_code:-none}); keeping the current config"
        rm -rf "$_gatygo_w"; return 1
    fi
    # 2. validate
    gatygo_parse_headers "$_gatygo_w/hdr" > "$_gatygo_w/headers.env"
    if [ "$(_gatygo_env_get "$_gatygo_w/headers.env" GATYGO_HWID_MAX_DEVICES)" = 1 ]; then
        gatygo_result error "panel reports the device limit reached for this subscription; keeping the current config"
        rm -rf "$_gatygo_w"; return 1
    fi
    if ! gatygo_sub_validate "$_gatygo_w/body" 2>/dev/null; then
        gatygo_result error "panel did not recognise the client (check the User-Agent and the subscription request rules); keeping the current config"
        rm -rf "$_gatygo_w"; return 1
    fi
    _gatygo_sub_changed=1
    [ -f "$GATYGO_STATE/subscription.json" ] \
        && [ "$(sha256sum < "$_gatygo_w/body")" = "$(sha256sum < "$GATYGO_STATE/subscription.json")" ] && _gatygo_sub_changed=0
    # 3. geo (at most daily while the subscription is unchanged), only when the subscription names the files
    if _gatygo_urls=$(gatygo_geo_urls "$_gatygo_w/headers.env") \
        && { [ "$_gatygo_sub_changed" = 1 ] || gatygo_geo_due; }; then
        gatygo_geo_fetch "${_gatygo_urls% *}" "${_gatygo_urls#* }" "$_gatygo_w/geo"
        [ $? -ne 1 ] || gatygo_log warn "geo download failed; keeping the current geo files"
    fi
    # 4–7. select, transform, test, swap
    _gatygo_prof=$(gatygo_apply_profile "$_gatygo_w/body" "$_gatygo_w/geo")
    _gatygo_apply=$?
    if [ "$_gatygo_apply" -eq 1 ]; then
        _gatygo_why=''; [ -n "$_gatygo_urls" ] || _gatygo_why=' (no geo file URLs in the subscription)'
        gatygo_result error "new config failed the xray test$_gatygo_why; keeping the current config"
        rm -rf "$_gatygo_w"; return 1
    fi
    GATYGO_SWAP_RESULT=$(cat "$GATYGO_RUN/swap-result" 2>/dev/null)
    _gatygo_install "$_gatygo_w/body" "$GATYGO_STATE/subscription.json" 600
    _gatygo_install "$_gatygo_w/headers.env" "$GATYGO_STATE/headers.env" 600
    rm -rf "$_gatygo_w"
    _gatygo_restarted=0
    if [ "$GATYGO_SWAP_RESULT" = changed ]; then _gatygo_restarted=1; _gatygo_reload; fi
    if [ "$_gatygo_apply" -eq 3 ]; then
        gatygo_result warning "profile '$GATYGO_PROFILE' is not in the subscription; using '$_gatygo_prof'" "$_gatygo_prof" "$_gatygo_restarted"
    else
        gatygo_result ok "subscription updated" "$_gatygo_prof" "$_gatygo_restarted"
    fi
    return 0
}
