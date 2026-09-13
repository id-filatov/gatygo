#!/bin/sh
# LAN DNS through xray. dnsmasq stays the LAN resolver and forwards to xray's dns-in.
# Relay host names get a direct dnsmasq entry (server=/host/<direct dns>): xray resolves its own
# outbound servers with the system resolver, which would otherwise loop back into xray.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"

# gatygo_relay_hosts XRAY_JSON — unique outbound server host names (IP literals skipped), one per line.
# No jq regex functions: OpenWrt's `jq` package is built without oniguruma (only `jq-full` has it).
# An IPv4 literal is a string of digits and dots (codepoints 48-57 and 46); IPv6 contains ':'.
gatygo_relay_hosts() {
    jq -r '[.outbounds[].settings.vnext[]?.address // empty
            | select((explode | all(. == 46 or (. >= 48 and . <= 57))) | not)
            | select(contains(":") | not)] | unique | .[]' "$1"
}

# gatygo_direct_dns — resolver for relay names: UCI direct_dns, else the WAN's first IPv4 DNS, else 1.1.1.1
gatygo_direct_dns() {
    if [ -n "$GATYGO_DIRECT_DNS" ]; then printf '%s\n' "$GATYGO_DIRECT_DNS"; return 0; fi
    _gatygo_ns=$(sed -n 's/^nameserver[[:space:]]*\([0-9][0-9.]*\).*/\1/p' \
        "$GATYGO_SYSROOT/tmp/resolv.conf.d/resolv.conf.auto" 2>/dev/null | head -n 1)
    printf '%s\n' "${_gatygo_ns:-1.1.1.1}"
}

_gatygo_dnsmasq_reload() {
    _gatygo_i=${GATYGO_DNSMASQ_INIT:-/etc/init.d/dnsmasq}
    [ -x "$_gatygo_i" ] && "$_gatygo_i" reload >/dev/null 2>&1
    return 0
}

# gatygo_dns_apply XRAY_JSON — point dnsmasq at xray and add direct entries for the relay names.
# The previous settings are saved once; re-applying rebuilds the list without touching the backup.
gatygo_dns_apply() {
    _gatygo_bk=$GATYGO_STATE/dnsmasq.backup
    if [ ! -f "$_gatygo_bk" ]; then
        {
            echo "SERVER=$(gatygo_shquote "$(uci -q get 'dhcp.@dnsmasq[0].server' 2>/dev/null)")"
            echo "NORESOLV=$(gatygo_shquote "$(uci -q get 'dhcp.@dnsmasq[0].noresolv' 2>/dev/null)")"
        } > "$_gatygo_bk.tmp" && chmod 600 "$_gatygo_bk.tmp" && mv "$_gatygo_bk.tmp" "$_gatygo_bk"
    fi
    _gatygo_direct=$(gatygo_direct_dns)
    uci -q delete 'dhcp.@dnsmasq[0].server'
    uci add_list "dhcp.@dnsmasq[0].server=127.0.0.1#$GATYGO_DNS_PORT"
    gatygo_relay_hosts "$1" | while read -r _gatygo_h; do
        uci add_list "dhcp.@dnsmasq[0].server=/$_gatygo_h/$_gatygo_direct"
    done
    uci set 'dhcp.@dnsmasq[0].noresolv=1'
    uci commit dhcp
    _gatygo_dnsmasq_reload
}

# gatygo_dns_restore — undo gatygo_dns_apply from the backup; no-op when there is none
gatygo_dns_restore() {
    _gatygo_bk=$GATYGO_STATE/dnsmasq.backup
    [ -f "$_gatygo_bk" ] || return 0
    _gatygo_srv=$(_gatygo_env_get "$_gatygo_bk" SERVER)
    _gatygo_nr=$(_gatygo_env_get "$_gatygo_bk" NORESOLV)
    uci -q delete 'dhcp.@dnsmasq[0].server'
    for _gatygo_s in $_gatygo_srv; do uci add_list "dhcp.@dnsmasq[0].server=$_gatygo_s"; done
    if [ -n "$_gatygo_nr" ]; then uci set "dhcp.@dnsmasq[0].noresolv=$_gatygo_nr"; else uci -q delete 'dhcp.@dnsmasq[0].noresolv'; fi
    uci commit dhcp
    rm -f "$_gatygo_bk"
    _gatygo_dnsmasq_reload
}
