#!/bin/sh
. "$(dirname "$0")/../lib.sh"
: > "$UCI_STUB_FILE"
. "$GATYGO_LIB/config.sh"
. "$GATYGO_LIB/firewall.sh"

gatygo_load_config
assert_eq "$(cat "$FIXTURES/nft-default.txt")" "$(gatygo_nft_ruleset)" "default ruleset"

uci set gatygo.main.lan_ifaces="br-lan eth2"
uci set gatygo.main.mark=0x10
uci set gatygo.main.tproxy_port=7777
uci set gatygo.main.dns_port=5300
uci set gatygo.main.ipv6_block=0
uci set gatygo.main.conn_per_device=50
uci set gatygo.main.conn_total=80
gatygo_load_config
assert_eq "$(cat "$FIXTURES/nft-custom.txt")" "$(gatygo_nft_ruleset)" "custom ports and caps, two interfaces, no IPv6 block"

report
