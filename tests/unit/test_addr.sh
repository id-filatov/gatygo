#!/bin/sh
. "$(dirname "$0")/../lib.sh"
: > "$UCI_STUB_FILE"
. "$GATYGO_LIB/config.sh"
. "$GATYGO_LIB/addr.sh"
. "$GATYGO_LIB/firewall.sh"
gatygo_load_config

# the canonical form: the one the page and the daemon store, compare and look statuses up by
while read -r in want; do
    assert_eq "$want" "$(gatygo_addr_norm "$in")" "norm: $in"
done <<'EOF'
203.0.113.5 203.0.113.5
203.0.113.5/32 203.0.113.5
203.0.113.7/24 203.0.113.0/24
0.0.0.0/0 0.0.0.0/0
198.51.100.0/22 198.51.100.0/22
2001:DB8::1 2001:db8::1
2001:0db8:0000:0000:0000:0000:0000:0001 2001:db8::1
2001:db8:0:0:1:0:0:1 2001:db8::1:0:0:1
2001:db8:0:1:1:1:1:1 2001:db8:0:1:1:1:1:1
2001:db8::1/128 2001:db8::1
2001:db8:abcd:12::7/48 2001:db8:abcd::/48
::/0 ::/0
::1 ::1
EOF
for bad in '' 256.1.1.1 1.2.3 1.2.3.4.5 010.1.1.1 1.2.3.4/33 1.2.3.4/024 1.2.3.4/ example.com \
           2001:db8::1::2 2001:db8:::1 12345::1 2001:db8::/129 ::ffff:1.2.3.4 fe80::1%eth0 '1.2.3.4 ' g::1; do
    assert_exit 1 "not an address: '$bad'" gatygo_addr_norm "$bad"
    assert_eq "" "$(gatygo_addr_norm "$bad")" "nothing printed for: '$bad'"
done

assert_eq "4 6" "$(gatygo_addr_family 203.0.113.5) $(gatygo_addr_family 2001:db8::1)" "family"

for a in 10.8.0.0/24 192.168.1.5 172.16.0.0/12 fe80::1 fd00::/8 fc00::/7; do assert_exit 0 "local: $a" gatygo_addr_local "$a"; done
for a in 203.0.113.0/24 0.0.0.0/0 8.0.0.0/7 172.0.0.0/8 2001:db8::/32 fc00::/6; do assert_exit 1 "not local: $a" gatygo_addr_local "$a"; done

assert_eq "203.0.113.0" "$(gatygo_addr_probe 203.0.113.0/24)" "probe: the first address"
assert_eq "1.0.0.0" "$(gatygo_addr_probe 0.0.0.0/0)" "probe: 0.0.0.0/0 skips 0.0.0.0/8"
assert_eq "203.0.113.128" "$(gatygo_addr_probe 203.0.113.0/24 203.0.113.0/25)" "probe: outside a narrower user rule"
assert_exit 1 "probe: covered by narrower rules" gatygo_addr_probe 203.0.113.0/24 203.0.113.0/25 203.0.113.128/25
assert_exit 1 "probe: all local" gatygo_addr_probe 10.0.0.0/8

# one list of the local networks for the firewall and the statuses
assert_eq "$(printf '%s\n' $GATYGO_RESERVED4 | paste -sd, - | sed 's/,/, /g')" \
    "$(gatygo_nft_ruleset | sed -n 's/^.*elements = { \(0\.0\.0\.0.*\) }$/\1/p')" "the nft set is GATYGO_RESERVED4"
assert_eq "$(printf '%s\n' $GATYGO_LOCAL6 | paste -sd, - | sed 's/,/, /g')" \
    "$(gatygo_nft_ruleset | sed -n 's/^.*ip6 daddr != { \(.*\) } counter drop$/\1/p')" "the IPv6 block leaves GATYGO_LOCAL6 alone"
assert_exit 0 "the IPv6 local ranges are GATYGO_LOCAL6's" sh -c '. "$GATYGO_LIB/config.sh"; . "$GATYGO_LIB/addr.sh"; GATYGO_LOCAL6="2001:db8::/32"; gatygo_addr_local 2001:db8:1::/48 && ! gatygo_addr_local fe80::1'

report
