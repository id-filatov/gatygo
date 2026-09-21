#!/bin/sh
. "$(dirname "$0")/../lib.sh"
export GATYGO_SYSROOT="$FIXTURES/sysroot"
. "$GATYGO_LIB/config.sh"

# defaults with an empty UCI
: > "$UCI_STUB_FILE"
gatygo_load_config
assert_eq "0" "$GATYGO_ENABLED" "enabled defaults to 0"
assert_eq "gatygo/dev" "$GATYGO_USER_AGENT" "UA defaults to gatygo/<version> (dev without version file)"
assert_eq "12345" "$GATYGO_TPROXY_PORT" "tproxy port default"
assert_eq "5353" "$GATYGO_DNS_PORT" "dns port default"
assert_eq "10808" "$GATYGO_CHECK_PORT" "check port default"
assert_eq "0xff" "$GATYGO_MARK" "mark default (hex string)"
assert_eq "255" "$GATYGO_MARK_DEC" "mark converted to decimal"
assert_eq "1" "$GATYGO_IPV6_BLOCK" "ipv6_block default"
assert_eq "br-lan" "$GATYGO_LAN_IFACES" "lan device falls back to br-lan when network.lan.device is unset"
assert_eq "warning" "$GATYGO_LOGLEVEL" "loglevel default"
assert_eq "" "$GATYGO_UPDATE_INTERVAL" "update interval empty by default"

# values from UCI
uci set gatygo.main.user_agent=MyRouter/9
uci set gatygo.main.mark=0x10
uci set gatygo.main.lan_ifaces="br-lan eth2"
uci set network.lan.device=br-guest
gatygo_load_config
assert_eq "MyRouter/9" "$GATYGO_USER_AGENT" "UA from UCI"
assert_eq "16" "$GATYGO_MARK_DEC" "mark 0x10 -> 16"
assert_eq "br-lan eth2" "$GATYGO_LAN_IFACES" "explicit lan_ifaces wins"
uci delete gatygo.main.lan_ifaces
gatygo_load_config
assert_eq "br-guest" "$GATYGO_LAN_IFACES" "lan device from network.lan.device"

# system facts from the sysroot
assert_eq "25.12.5" "$(gatygo_os_version)" "DISTRIB_RELEASE from openwrt_release"
assert_eq "qemu-qemu-virtual-machine" "$(gatygo_device_model)" "board_name"

# --- send_hwid: default on
uci delete gatygo.main.send_hwid; gatygo_load_config
assert_eq "1" "$GATYGO_SEND_HWID" "send_hwid defaults to 1"
uci set gatygo.main.send_hwid=0; gatygo_load_config
assert_eq "0" "$GATYGO_SEND_HWID" "send_hwid from UCI"

# --- connection caps: numbers from UCI, anything else falls back to the default (they go into the nft ruleset)
: > "$UCI_STUB_FILE"; gatygo_load_config
assert_eq "600" "$GATYGO_CONN_PER_DEVICE" "conn_per_device default"
assert_eq "1000" "$GATYGO_CONN_TOTAL" "conn_total default"
uci set gatygo.main.conn_per_device=300; uci set gatygo.main.conn_total=2500; gatygo_load_config
assert_eq "300 2500" "$GATYGO_CONN_PER_DEVICE $GATYGO_CONN_TOTAL" "caps from UCI"
uci set gatygo.main.conn_per_device=0; uci set gatygo.main.conn_total="1000; drop"; gatygo_load_config
assert_eq "600 1000" "$GATYGO_CONN_PER_DEVICE $GATYGO_CONN_TOTAL" "zero and non-numbers fall back to the defaults"
uci set gatygo.main.conn_per_device=0600; uci set gatygo.main.conn_total=-5; gatygo_load_config
assert_eq "600 1000" "$GATYGO_CONN_PER_DEVICE $GATYGO_CONN_TOTAL" "a leading zero and a sign fall back to the defaults"

report
