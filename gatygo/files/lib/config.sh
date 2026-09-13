#!/bin/sh
# Load /etc/config/gatygo into GATYGO_* variables and define the paths every module uses.
# GATYGO_SYSROOT prefixes system files (tests point it at a fake root).

. "${GATYGO_LIB:-/usr/lib/gatygo}/common.sh"

GATYGO_STATE=${GATYGO_STATE:-/etc/gatygo}
GATYGO_RUN=${GATYGO_RUN:-/var/run/gatygo}
GATYGO_ASSETS=${GATYGO_ASSETS:-/usr/share/xray}
GATYGO_LOG=${GATYGO_LOG:-/var/log/gatygo.log}
GATYGO_SYSROOT=${GATYGO_SYSROOT:-}
GATYGO_GEOSITE_DEFAULT=https://geo.example.com/geosite.dat
GATYGO_GEOIP_DEFAULT=https://geo.example.com/geoip.dat

# gatygo_cfg KEY DEFAULT — option gatygo.main.KEY, or DEFAULT when unset or empty
gatygo_cfg() {
    _gatygo_v=$(uci -q get "gatygo.main.$1" 2>/dev/null)
    printf '%s\n' "${_gatygo_v:-$2}"
}

# gatygo_os_version — DISTRIB_RELEASE of the running OpenWrt (x-ver-os header)
gatygo_os_version() {
    sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" "$GATYGO_SYSROOT/etc/openwrt_release" 2>/dev/null
}

# gatygo_device_model — board name (x-device-model header)
gatygo_device_model() {
    cat "$GATYGO_SYSROOT/tmp/sysinfo/board_name" 2>/dev/null || echo unknown
}

gatygo_load_config() {
    GATYGO_VERSION=$(cat "${GATYGO_LIB:-/usr/lib/gatygo}/version" 2>/dev/null || echo dev)
    GATYGO_ENABLED=$(gatygo_cfg enabled 0)
    GATYGO_SUB_URL=$(gatygo_cfg sub_url "")
    GATYGO_USER_AGENT=$(gatygo_cfg user_agent "gatygo/$GATYGO_VERSION")
    GATYGO_HWID=$(gatygo_cfg hwid "")
    GATYGO_PROFILE=$(gatygo_cfg profile "")
    GATYGO_UPDATE_INTERVAL=$(gatygo_cfg update_interval "")
    GATYGO_TPROXY_PORT=$(gatygo_cfg tproxy_port 12345)
    GATYGO_DNS_PORT=$(gatygo_cfg dns_port 5353)
    GATYGO_MARK=$(gatygo_cfg mark 0xff)
    GATYGO_MARK_DEC=$((GATYGO_MARK))
    GATYGO_IPV6_BLOCK=$(gatygo_cfg ipv6_block 1)
    GATYGO_LAN_IFACES=$(gatygo_cfg lan_ifaces "")
    [ -n "$GATYGO_LAN_IFACES" ] || GATYGO_LAN_IFACES=$(uci -q get network.lan.device 2>/dev/null)
    [ -n "$GATYGO_LAN_IFACES" ] || GATYGO_LAN_IFACES=br-lan
    GATYGO_DIRECT_DNS=$(gatygo_cfg direct_dns "")
    GATYGO_LOGLEVEL=$(gatygo_cfg loglevel warning)
    export GATYGO_VERSION GATYGO_ENABLED GATYGO_SUB_URL GATYGO_USER_AGENT GATYGO_HWID GATYGO_PROFILE \
        GATYGO_UPDATE_INTERVAL GATYGO_TPROXY_PORT GATYGO_DNS_PORT GATYGO_MARK GATYGO_MARK_DEC \
        GATYGO_IPV6_BLOCK GATYGO_LAN_IFACES GATYGO_DIRECT_DNS GATYGO_LOGLEVEL \
        GATYGO_STATE GATYGO_RUN GATYGO_ASSETS GATYGO_LOG GATYGO_SYSROOT
}
