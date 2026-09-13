#!/bin/sh
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_SYSROOT="$FIXTURES/sysroot" GATYGO_STATE="$tmp/state" GATYGO_DNSMASQ_INIT=/src/tests/stubs/dnsmasq-init \
       GATYGO_DNSMASQ_LOG="$tmp/dnsmasq.log"
mkdir -p "$GATYGO_STATE"; : > "$UCI_STUB_FILE"; : > "$GATYGO_DNSMASQ_LOG"
. "$GATYGO_LIB/config.sh"
. "$GATYGO_LIB/transform.sh"
. "$GATYGO_LIB/dns.sh"
jq '.[0]' "$FIXTURES/subscription.json" > "$tmp/in.json"
gatygo_transform "$tmp/in.json" "$tmp/xray.json" 12345 5353 255 warning /tmp/x.log
_expected_hosts=$(jq -r '[.outbounds[].settings.vnext[]?.address] | unique | .[]' "$tmp/in.json")

# --- relay hosts: every unique address of the profile (the fixture has host names only)
assert_eq "$_expected_hosts" "$(gatygo_relay_hosts "$tmp/xray.json")" "unique relay host names"
printf '{"outbounds":[{"settings":{"vnext":[{"address":"1.2.3.4"}]}},{"settings":{"vnext":[{"address":"2001:db8::1"}]}},{"settings":{"vnext":[{"address":"a.example.com"}]}},{"protocol":"freedom"}]}' > "$tmp/mixed.json"
assert_eq "a.example.com" "$(gatygo_relay_hosts "$tmp/mixed.json")" "IPv4/IPv6 literals and outbounds without vnext are skipped"

# --- direct resolver
gatygo_load_config
assert_eq "10.0.2.3" "$(gatygo_direct_dns)" "WAN DNS from resolv.conf.auto"
uci set gatygo.main.direct_dns=9.9.9.9; gatygo_load_config
assert_eq "9.9.9.9" "$(gatygo_direct_dns)" "UCI direct_dns wins"
uci delete gatygo.main.direct_dns; gatygo_load_config
assert_eq "1.1.1.1" "$(GATYGO_SYSROOT=/nonexistent gatygo_direct_dns)" "fallback when no WAN DNS"

# --- apply: backup once, server list, noresolv, reload
uci add_list 'dhcp.@dnsmasq[0].server=8.8.8.8'
uci add_list 'dhcp.@dnsmasq[0].server=/corp.example/10.1.1.1'
gatygo_dns_apply "$tmp/xray.json"
assert_exit 0 "backup written" test -s "$GATYGO_STATE/dnsmasq.backup"
assert_eq "SERVER='8.8.8.8 /corp.example/10.1.1.1'" "$(grep ^SERVER= "$GATYGO_STATE/dnsmasq.backup")" "previous server list saved"
assert_eq "NORESOLV=''" "$(grep ^NORESOLV= "$GATYGO_STATE/dnsmasq.backup")" "previous noresolv saved (unset)"
_servers=$(uci get 'dhcp.@dnsmasq[0].server')
assert_eq "127.0.0.1#5353" "${_servers%% *}" "xray dns-in is the first server"
assert_eq "$(printf '%s\n' "$_expected_hosts" | wc -l | tr -d ' ')" "$(printf '%s' "$_servers" | tr ' ' '\n' | grep -c '^/.*/10.0.2.3$')" "one direct entry per relay host"
assert_eq "1" "$(uci get 'dhcp.@dnsmasq[0].noresolv')" "noresolv set"
assert_eq "reload" "$(cat "$GATYGO_DNSMASQ_LOG")" "dnsmasq reloaded"

# --- apply again: backup untouched, list rebuilt (no duplicates)
gatygo_dns_apply "$tmp/xray.json"
assert_eq "SERVER='8.8.8.8 /corp.example/10.1.1.1'" "$(grep ^SERVER= "$GATYGO_STATE/dnsmasq.backup")" "backup not overwritten on re-apply"
assert_eq "1" "$(uci get 'dhcp.@dnsmasq[0].server' | tr ' ' '\n' | grep -c '^127.0.0.1#5353$')" "no duplicate entries"

# --- restore
: > "$GATYGO_DNSMASQ_LOG"
gatygo_dns_restore
assert_eq "8.8.8.8 /corp.example/10.1.1.1" "$(uci get 'dhcp.@dnsmasq[0].server')" "server list restored"
assert_exit 1 "noresolv removed again" uci -q get 'dhcp.@dnsmasq[0].noresolv'
assert_exit 1 "backup deleted" test -e "$GATYGO_STATE/dnsmasq.backup"
assert_eq "reload" "$(cat "$GATYGO_DNSMASQ_LOG")" "dnsmasq reloaded on restore"
: > "$GATYGO_DNSMASQ_LOG"
gatygo_dns_restore
assert_eq "" "$(cat "$GATYGO_DNSMASQ_LOG")" "restore without backup is a no-op"

# --- restore when noresolv had a value
uci set 'dhcp.@dnsmasq[0].noresolv=0'
gatygo_dns_apply "$tmp/xray.json"; gatygo_dns_restore
assert_eq "0" "$(uci get 'dhcp.@dnsmasq[0].noresolv')" "noresolv value restored"

rm -rf "$tmp"
report
