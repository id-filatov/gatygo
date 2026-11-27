#!/bin/sh
# The update cycle: core → fetch → validate → geo → select → transform → test → swap,
# plus the pieces the CLI reuses for `select`.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/hwid.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/headers.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/subscription.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/transform.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/check.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/fetch.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/geo.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/core.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/relay.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/rules.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/suburl.sh"

GATYGO_INIT=${GATYGO_INIT:-/etc/init.d/gatygo}

# _gatygo_record FILE RESULT CODE MESSAGE [PROFILE] [RESTARTED] — write an outcome file and log the message
_gatygo_record() {
    _gatygo_rf=$1; shift
    {
        echo "RESULT=$(gatygo_shquote "$1")"
        echo "CODE=$(gatygo_shquote "$2")"
        echo "TIME=$(date +%s)"
        echo "MESSAGE=$(gatygo_shquote "$3")"
        echo "PROFILE=$(gatygo_shquote "${4:-}")"
        echo "RESTARTED=$(gatygo_shquote "${5:-0}")"
    } > "$_gatygo_rf.tmp" && mv "$_gatygo_rf.tmp" "$_gatygo_rf"
    case $1 in
        error) gatygo_log error "$3" ;;
        warning) gatygo_log warn "$3" ;;
        *) gatygo_log info "$3" ;;
    esac
}

# gatygo_result RESULT CODE MESSAGE [PROFILE] [RESTARTED] — record the outcome of an update for the UI
# and log it. CODE is a stable name of the cause (the page picks its wording by it); MESSAGE is for
# the log. One small file in the state dir, overwritten each time: the panel shows the last real
# result right after a reboot instead of nothing until the boot-time update has run.
gatygo_result() {
    mkdir -p "$GATYGO_STATE" && chmod 700 "$GATYGO_STATE"
    _gatygo_record "$GATYGO_STATE/last-update.env" "$@"
}

# gatygo_select_result RESULT CODE MESSAGE [PROFILE] [RESTARTED] — the same for a switch of the
# profile, kept apart: a switch neither hides a failed update nor counts as one. In the run dir
# (tmpfs); the next update applies the saved profile again and drops it.
gatygo_select_result() {
    mkdir -p "$GATYGO_RUN"
    _gatygo_record "$GATYGO_RUN/last-select.env" "$@"
}

# gatygo_xray_test CONFIG ASSET_DIR — `xray run -test`; on failure log the tail of xray's output
gatygo_xray_test() {
    _gatygo_out=$(XRAY_LOCATION_ASSET=$2 "$GATYGO_XRAY" run -test -c "$1" 2>&1) && return 0
    gatygo_log error "xray -test failed: $(printf '%s' "$_gatygo_out" | grep -v -e '^Xray ' -e '^A unified' | tail -n 3 | tr '\n' ' ')"
    return 1
}

# gatygo_stage_assets STAGE TESTDIR — TESTDIR gets the staged dats plus the current ones for the rest.
# A staged dat is hard-linked when it can be (both in /tmp), a current one that links to a default
# dat in RAM is linked to it: the default ones are 28 MB of RAM.
gatygo_stage_assets() {
    for _gatygo_n in geosite.dat geoip.dat; do
        if [ -f "$1/$_gatygo_n" ]; then ln -f "$1/$_gatygo_n" "$2/$_gatygo_n" 2>/dev/null || cp -p "$1/$_gatygo_n" "$2/$_gatygo_n"
        elif [ -L "$GATYGO_ASSETS/$_gatygo_n" ]; then ln -s "$(readlink "$GATYGO_ASSETS/$_gatygo_n")" "$2/$_gatygo_n"
        elif [ -f "$GATYGO_ASSETS/$_gatygo_n" ]; then cp -p "$GATYGO_ASSETS/$_gatygo_n" "$2/$_gatygo_n"
        fi
    done
}

# _gatygo_install SRC DST MODE — copy then rename inside DST's directory (atomic on the same fs)
_gatygo_install() {
    cp -p "$1" "$2.tmp" && chmod "$3" "$2.tmp" && mv "$2.tmp" "$2"
}

# gatygo_swap NEW_XRAY STAGE — install the config and any staged dat that differs; prints
# changed|unchanged. STAGE/.default: the staged dats are the default ones (lib/geo.sh, in RAM); a dat
# of the provider's replaces a link to a default one, and the default one goes.
gatygo_swap() {
    _gatygo_changed=0
    if [ ! -f "$GATYGO_STATE/xray.json" ] || [ "$(sha256sum < "$1")" != "$(sha256sum < "$GATYGO_STATE/xray.json")" ]; then
        _gatygo_install "$1" "$GATYGO_STATE/xray.json" 600 && _gatygo_changed=1
    fi
    mkdir -p "$GATYGO_ASSETS"
    if [ -f "$2/.default" ]; then
        [ "$(gatygo_geo_install_default "$2")" = changed ] && _gatygo_changed=1
    else
        for _gatygo_n in geosite.dat geoip.dat; do
            [ -f "$2/$_gatygo_n" ] || continue
            if [ -L "$GATYGO_ASSETS/$_gatygo_n" ] || [ ! -f "$GATYGO_ASSETS/$_gatygo_n" ] \
                || [ "$(sha256sum < "$2/$_gatygo_n")" != "$(sha256sum < "$GATYGO_ASSETS/$_gatygo_n")" ]; then
                _gatygo_install "$2/$_gatygo_n" "$GATYGO_ASSETS/$_gatygo_n" 644 && _gatygo_changed=1 \
                    && rm -f "$GATYGO_GEO_TMP/$_gatygo_n"
            else
                touch "$GATYGO_ASSETS/$_gatygo_n"
            fi
        done
    fi
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
    _gatygo_ur=$(gatygo_rules_json)
    if ! gatygo_transform "$_gatygo_t/selected.json" "$_gatygo_t/xray.json" "$GATYGO_TPROXY_PORT" "$GATYGO_DNS_PORT" \
            "$GATYGO_MARK_DEC" "$GATYGO_LOGLEVEL" "$GATYGO_CHECK_PORT" "$(gatygo_check_secret)" "$_gatygo_ur"; then
        rm -rf "$_gatygo_t"; return 1
    fi
    mkdir -p "$_gatygo_t/assets"
    gatygo_stage_assets "$2" "$_gatygo_t/assets"
    if ! gatygo_xray_test "$_gatygo_t/xray.json" "$_gatygo_t/assets"; then rm -rf "$_gatygo_t"; return 1; fi
    GATYGO_SWAP_RESULT=$(gatygo_swap "$_gatygo_t/xray.json" "$2")
    mkdir -p "$GATYGO_RUN" && printf '%s\n' "$GATYGO_SWAP_RESULT" > "$GATYGO_RUN/swap-result"
    # xray.json carries no profile name: keep it next to the config, so status knows the profile
    # in use whatever the later updates end with. Rewritten only when it changes (flash wear).
    if [ "$(cat "$GATYGO_STATE/profile" 2>/dev/null)" != "$_gatygo_prof" ]; then
        printf '%s\n' "$_gatygo_prof" > "$_gatygo_t/profile" && _gatygo_install "$_gatygo_t/profile" "$GATYGO_STATE/profile" 600
    fi
    # the user's rules the installed config was built with: `gatygo rules` holds the statuses back
    # until they match the settings (lib/route.sh)
    if [ "$(cat "$GATYGO_STATE/rules.json" 2>/dev/null)" != "$_gatygo_ur" ]; then
        printf '%s\n' "$_gatygo_ur" > "$_gatygo_t/rules.json" && _gatygo_install "$_gatygo_t/rules.json" "$GATYGO_STATE/rules.json" 600
    fi
    rm -rf "$_gatygo_t"
    printf '%s\n' "$_gatygo_prof"
    return "$_gatygo_sel"
}

# _gatygo_reload — re-submit the procd instance when the service runs: procd restarts xray only
# if xray.json or a geo file changed. `start` is used on purpose: `reload` is the settings-changed
# hook of the init script and would kick another update.
_gatygo_reload() {
    [ -x "$GATYGO_INIT" ] || return 0
    "$GATYGO_INIT" running xray >/dev/null 2>&1 || return 0
    "$GATYGO_INIT" start >/dev/null 2>&1
}

# _gatygo_sub_download SAVED_WAY HWID DIR — download the subscription into DIR/body, DIR/hdr and
# DIR/headers.env. The addresses: the link, then the spares kept for it (lib/suburl.sh). On each,
# the ways of asking (lib/fetch.sh), SAVED_WAY first. An answer is one of:
#   none (curl failed)                 the address is down: the next address; to mixed-json after
#                                      the address answered 200, only its /json is: the next way
#   not 200, to mixed-json             the server has no /json: the next way
#   not 200, to another way            the address refused: the next address, unless it already
#                                      answered 200 (a refusal of a name: no other name is tried)
#   200, the device limit reached      stop
#   200, a Xray JSON list              done
#   200, anything else                 the next way
# An address that answered 200 is the last one tried. Only the link's first request retries: the
# page stays locked while an update runs. Sets _gatygo_used (the address), _gatygo_got (the way),
# _gatygo_code (the status of the link's first request without /json) and _gatygo_refused (1 when
# SAVED_WAY was refused, or its /json did not answer: the next update starts over). exit 0 done,
# 1 no address answered 200, 2 the device limit, 3 an address answered, but no way gave a Xray
# JSON list.
_gatygo_sub_download() {
    _gatygo_code='' _gatygo_coded=0 _gatygo_used='' _gatygo_got='' _gatygo_refused=0 _gatygo_tries=3
    _gatygo_addrs=$(printf 'link %s\n' "$GATYGO_SUB_URL"; gatygo_suburl_spares "$GATYGO_SUB_URL")
    while read -r _gatygo_kind _gatygo_addr; do
        [ -n "$_gatygo_addr" ] || continue
        _gatygo_answered=0
        for _gatygo_k in $(gatygo_way_list "$1"); do
            # a /json the server does not have is no error
            _gatygo_lvl=error
            [ "$_gatygo_k" != mixed-json ] || _gatygo_lvl=info
            _gatygo_c=$(gatygo_fetch "$(gatygo_way_url "$_gatygo_k" "$_gatygo_addr")" "$(gatygo_way_ua "$_gatygo_k")" \
                "$2" "$3/body" "$3/hdr" "$_gatygo_tries" "$_gatygo_lvl")
            _gatygo_rc=$?
            _gatygo_tries=0
            if [ "$_gatygo_kind" = link ] && [ "$_gatygo_k" != mixed-json ] && [ "$_gatygo_coded" = 0 ]; then
                _gatygo_code=$_gatygo_c _gatygo_coded=1
            fi
            if [ "$_gatygo_k" = "$1" ] && { [ "$_gatygo_rc" -eq 1 ] || [ "$_gatygo_k" = mixed-json ]; } \
                && [ "$_gatygo_rc" -ne 0 ]; then
                _gatygo_refused=1
            fi
            if [ "$_gatygo_rc" -eq 2 ]; then
                [ "$_gatygo_k" = mixed-json ] && [ "$_gatygo_answered" = 1 ] && continue
                break
            fi
            if [ "$_gatygo_rc" -ne 0 ]; then
                [ "$_gatygo_k" != mixed-json ] || continue
                [ "$_gatygo_answered" = 0 ] || return 3
                break
            fi
            _gatygo_answered=1
            gatygo_parse_headers "$3/hdr" > "$3/headers.env"
            [ "$(_gatygo_env_get "$3/headers.env" GATYGO_HWID_MAX_DEVICES)" != 1 ] || return 2
            if gatygo_sub_validate "$3/body" 2>/dev/null; then
                _gatygo_used=$_gatygo_addr _gatygo_got=$_gatygo_k
                [ "$_gatygo_kind" = link ] || gatygo_log info "subscription downloaded from the $_gatygo_kind address"
                return 0
            fi
        done
        [ "$_gatygo_answered" = 0 ] || return 3
    done <<EOF
$_gatygo_addrs
EOF
    return 1
}

# gatygo_update — exit 0 on ok/warning, 1 on error (the current config is never touched then)
gatygo_update() {
    gatygo_load_config
    # no link (never connected, or deleted by `gatygo forget`): nothing to update and nothing to
    # record — an update scheduled before a delete must not leave a result behind. 1: nothing was
    # updated, so start_service still refuses to start without a config.
    if [ -z "$GATYGO_SUB_URL" ]; then gatygo_log info "update skipped: no subscription link"; return 1; fi
    mkdir -p "$GATYGO_STATE" && chmod 700 "$GATYGO_STATE"
    # 0. the xray core: the pinned one, or at least the one in place (the config test needs it)
    _gatygo_core=$(gatygo_core_ensure) || {
        gatygo_result error core_failed "the xray core is not installed and could not be downloaded (see the lines above)"
        return 1
    }
    _gatygo_hwid=''
    [ "$GATYGO_SEND_HWID" = 1 ] && _gatygo_hwid=$(gatygo_hwid_ensure)
    _gatygo_w=$(mktemp -d)
    mkdir -p "$_gatygo_w/geo"

    # 1–2. fetch and validate: the link, then its spare addresses, each asked in the ways of
    # lib/fetch.sh, the one that worked last time first
    _gatygo_way=$(gatygo_way_saved "$GATYGO_SUB_URL")
    _gatygo_sub_download "$_gatygo_way" "$_gatygo_hwid" "$_gatygo_w"
    _gatygo_dl=$?
    # a saved way that failed is not kept: with no settings to change, it would stay stuck
    if [ "$_gatygo_dl" != 0 ] && [ "$_gatygo_refused" = 1 ]; then
        rm -f "$GATYGO_STATE/sub-way.env"
        gatygo_log info "subscription: the $_gatygo_way request failed; the next update tries every way again"
    fi
    case $_gatygo_dl in
        1)
            gatygo_result error fetch_failed "subscription download failed (HTTP ${_gatygo_code:-none}); keeping the current config"
            rm -rf "$_gatygo_w"; return 1 ;;
        2)
            gatygo_result error device_limit "panel reports the device limit reached for this subscription; keeping the current config"
            rm -rf "$_gatygo_w"; return 1 ;;
        3)
            gatygo_result error not_recognised "the panel answered, but none of the ways gatygo asks gave a Xray JSON list; keeping the current config"
            rm -rf "$_gatygo_w"; return 1 ;;
    esac
    [ "$_gatygo_got" = "$_gatygo_way" ] \
        || gatygo_log info "subscription: the panel gives a Xray JSON list to the $_gatygo_got request"
    gatygo_way_save "$_gatygo_got" "$GATYGO_SUB_URL"
    _gatygo_sub_changed=1
    [ -f "$GATYGO_STATE/subscription.json" ] \
        && [ "$(sha256sum < "$_gatygo_w/body")" = "$(sha256sum < "$GATYGO_STATE/subscription.json")" ] && _gatygo_sub_changed=0
    # 3. geo (at most daily while the subscription and the URLs are unchanged): the subscription's
    # files, or the default ones when it names geo rules but gives no files (lib/geo.sh)
    _gatygo_geo_ok=0 _gatygo_geo_fail=0
    if _gatygo_urls=$(gatygo_geo_urls "$_gatygo_w/headers.env" "$_gatygo_w/body") \
        && { [ "$_gatygo_sub_changed" = 1 ] || gatygo_geo_due \
            || ! gatygo_geo_source_matches "${_gatygo_urls% *}" "${_gatygo_urls#* }"; }; then
        if gatygo_geo_is_default "${_gatygo_urls% *}"; then
            : > "$_gatygo_w/geo/.default"
            gatygo_log info "geo: the subscription names geo rules but gives no geo files; using Loyalsoldier's"
        fi
        gatygo_geo_fetch "${_gatygo_urls% *}" "${_gatygo_urls#* }" "$_gatygo_w/geo"
        case $? in
            1) _gatygo_geo_fail=1; gatygo_log warn "geo download failed; keeping the current geo files" ;;
            *) _gatygo_geo_ok=1 ;;
        esac
    fi
    # 4–7. select, transform, test, swap
    _gatygo_prof=$(gatygo_apply_profile "$_gatygo_w/body" "$_gatygo_w/geo")
    _gatygo_apply=$?
    if [ "$_gatygo_apply" -eq 1 ]; then
        _gatygo_why=''; [ "$_gatygo_geo_fail" = 0 ] || _gatygo_why=' (the geo files could not be downloaded)'
        gatygo_result error test_failed "new config failed the xray test$_gatygo_why; keeping the current config"
        rm -rf "$_gatygo_w"; return 1
    fi
    GATYGO_SWAP_RESULT=$(cat "$GATYGO_RUN/swap-result" 2>/dev/null)
    # the dats now installed (fetched or confirmed by 304) came from these URLs: next time conditional
    [ "$_gatygo_geo_ok" = 1 ] && gatygo_geo_record "${_gatygo_urls% *}" "${_gatygo_urls#* }"
    _gatygo_install "$_gatygo_w/body" "$GATYGO_STATE/subscription.json" 600
    _gatygo_install "$_gatygo_w/headers.env" "$GATYGO_STATE/headers.env" 600
    rm -rf "$_gatygo_w"
    # the spares for next time, and a move of the subscription to a new address
    gatygo_fetched_note "$GATYGO_SUB_URL" "$GATYGO_SEND_HWID"
    gatygo_suburl_record "$GATYGO_SUB_URL" "$_gatygo_used" "$GATYGO_STATE/headers.env"
    _gatygo_restarted=0
    # a replaced core restarts xray too: the init script makes the core a part of the instance
    if [ "$GATYGO_SWAP_RESULT" = changed ] || [ "$_gatygo_core" = installed ]; then _gatygo_restarted=1; _gatygo_reload
    # so does a relay that moved while xray stays on its old address (lib/relay.sh)
    elif gatygo_relay_moved "$GATYGO_STATE/xray.json"; then gatygo_relay_reconnect; _gatygo_restarted=1; _gatygo_reload
    fi
    rm -f "$GATYGO_RUN/last-select.env"
    if [ "$_gatygo_apply" -eq 3 ]; then
        gatygo_result warning profile_missing "profile '$GATYGO_PROFILE' is not in the subscription; using '$_gatygo_prof'" "$_gatygo_prof" "$_gatygo_restarted"
    else
        gatygo_result ok updated "subscription updated" "$_gatygo_prof" "$_gatygo_restarted"
    fi
    return 0
}
