#!/bin/sh
# gatygo forget: drop the subscription and everything it brought, the way a fresh install is.
# The VPN is stopped first; the xray core (not tied to a subscription) and the device ID (derived
# from the hardware: a new one would come out the same) stay.
# Requires config.sh and service.sh (the update lock).

GATYGO_INIT=${GATYGO_INIT:-/etc/init.d/gatygo}
GATYGO_DEFAULTS=${GATYGO_DEFAULTS:-${GATYGO_LIB:-/usr/lib/gatygo}/defaults.config}

# gatygo_forget — exit 0 done, 2 an update is running (nothing touched), 1 the VPN could not be
# stopped (nothing erased), 3 the settings could not be written (a full overlay: the link may
# still be in the config)
gatygo_forget() {
    # an update is never cut off halfway through writing its files
    gatygo_update_lock || return 2
    # the geo files are gatygo's when it recorded where it downloaded them from: read before the wipe
    _gatygo_geo=0
    [ -f "$GATYGO_STATE/geo-source.env" ] && _gatygo_geo=1
    # the usual stop, running or not: dnsmasq gets its DNS back (from dnsmasq.backup, hence before
    # the wipe), the nft table goes (with an on_crash=block block), the cron line goes. The boot
    # link stays, as after an install: enabled=0 keeps the service off, and Enable brings it back.
    if ! "$GATYGO_INIT" stop >/dev/null 2>&1; then
        gatygo_update_unlock
        return 1
    fi
    # everything the subscription brought; the directories stay (/etc/gatygo is in the keep list).
    # The state goes before the run dir: see gatygo_check_store.
    case $GATYGO_STATE:$GATYGO_RUN in /?*:/?*) ;; *) gatygo_update_unlock; return 1 ;; esac
    rm -rf "$GATYGO_STATE"/* "$GATYGO_STATE"/.[!.]*
    [ "$_gatygo_geo" = 1 ] && rm -f "$GATYGO_ASSETS/geosite.dat" "$GATYGO_ASSETS/geoip.dat"
    for _gatygo_f in "$GATYGO_RUN"/* "$GATYGO_RUN"/.[!.]*; do
        [ -e "$_gatygo_f" ] || continue
        [ "$_gatygo_f" = "$GATYGO_RUN/update.lock" ] || rm -rf "$_gatygo_f"
    done
    # the settings back to the package defaults, the device ID kept
    _gatygo_hwid=$(uci -q get gatygo.main.hwid 2>/dev/null)
    uci -q delete gatygo.main
    uci set gatygo.main=gatygo
    sed -n "s/^[[:space:]]*option \([a-z0-9_]*\) '\(.*\)'\$/\1=\2/p" "$GATYGO_DEFAULTS" | while IFS= read -r _gatygo_o; do
        uci set "gatygo.main.$_gatygo_o"
    done
    [ -n "$_gatygo_hwid" ] && uci set gatygo.main.hwid="$_gatygo_hwid"
    if ! uci commit gatygo; then
        gatygo_update_unlock
        return 3
    fi
    gatygo_log info "subscription removed"
    gatygo_update_unlock
    return 0
}
