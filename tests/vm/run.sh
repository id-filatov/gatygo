#!/bin/bash
# End-to-end check of the gatygo package on the lab VM. Run from the repo root:
#   tests/vm/run.sh [gatygo.apk]
# Needs: ssh alias `lab` with ~/lab/openwrt.sh, python3 on the lab host
# for the mock panel, and FIXTURE (default tests/fixtures/subscription.json).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APK=${1:-$(ls "$ROOT"/bin/packages/x86_64/gatygo/gatygo-*.apk 2>/dev/null | tail -n 1)}
FIXTURE=${FIXTURE:-$ROOT/tests/fixtures/subscription.json}
[ -f "$APK" ] || { echo "no .apk: build it with tools/build-apk.sh" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "no fixture at $FIXTURE" >&2; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }
# vm CMD — run CMD inside the OpenWrt VM (quoted once for the lab host shell)
vm()  { ssh lab "cd ~/lab && ./openwrt.sh ssh -o BatchMode=yes $(printf '%q' "$1")"; }
# check MSG CMD — pass when CMD succeeds inside the VM
check() { if vm "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
# expect MSG EXPECTED CMD — pass when CMD's stdout inside the VM equals EXPECTED
expect() { local got; got=$(vm "$3" 2>/dev/null); if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 (got: $got)"; fi; }

echo "== 0. lab: mock panel + files"
scp -q "$APK" lab:lab/gatygo.apk
scp -q "$FIXTURE" lab:lab/fixture.json
scp -q "$ROOT/tests/mock/sub_server.py" lab:lab/sub_server.py
ssh lab 'mkdir -p lab/geo' && scp -q "$ROOT"/tests/fixtures/geo/*.dat lab:lab/geo/
ssh lab 'cd lab && pkill -f sub_server.py; nohup python3 sub_server.py 8787 fixture.json geo http://10.0.2.2:8787 > mock.log 2>&1 &
             i=0; until curl -fs -o /dev/null localhost:8787/log; do i=$((i + 1)); [ $i -lt 20 ] || exit 1; sleep 0.5; done' \
    && ok "mock panel up on the lab host" || bad "mock panel"
# dropbear has no sftp server: force the legacy scp protocol
ssh lab 'cd lab && ./openwrt.sh wait >/dev/null && scp -q -O -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR gatygo.apk root@127.0.0.1:/tmp/gatygo.apk'
# the VM's busybox has no `timeout`: /tmp/tmo SECS CMD... runs CMD and kills it after SECS
vm 'printf "%s\n" "#!/bin/sh" "t=\$1; shift" "\"\$@\" & p=\$!" "( sleep \"\$t\"; kill \"\$p\" 2>/dev/null ) & w=\$!" "wait \"\$p\"; rc=\$?" "kill \"\$w\" 2>/dev/null" "exit \$rc" > /tmp/tmo && chmod +x /tmp/tmo'
check "tmo helper works" '/tmp/tmo 1 sleep 5; test $? -ne 0 && /tmp/tmo 3 true'

echo "== 1. install"
vm 'ip netns del c1 2>/dev/null; ip link del veth-c1 2>/dev/null; /etc/init.d/gatygo stop 2>/dev/null; apk del gatygo >/dev/null 2>&1; rm -rf /etc/gatygo /var/run/gatygo /etc/config/gatygo; true'
check "apk installs" 'apk add --allow-untrusted /tmp/gatygo.apk >/dev/null 2>&1'
expect "gatygo version" "0.1.0" 'gatygo version'
check "init script enabled" 'test -e /etc/rc.d/S95gatygo'

echo "== 2. configure + start"
vm 'uci set gatygo.main.enabled=1; uci set gatygo.main.sub_url=http://10.0.2.2:8787/sub; uci commit gatygo'
check "start" '/etc/init.d/gatygo start && sleep 5'
expect "xray running" "true" 'gatygo status | jq -r .running'
expect "first balancer tile applied" "🌐 Auto" 'gatygo status | jq -r .profile_used'
expect "update result ok" "ok" 'gatygo status | jq -r .last_update.result'
check "xray.json installed 0600" 'test "$(ls -l /etc/gatygo/xray.json | cut -c1-10)" = -rw-------'
check "geo files installed" 'test -s /usr/share/xray/geosite.dat && test -s /usr/share/xray/geoip.dat'

echo "== 3. firewall"
check "nft table inet gatygo present" 'nft list table inet gatygo >/dev/null'
check "policy rule present" 'ip rule | grep -q "fwmark 0x1 lookup 100"'
check "local route in table 100" 'ip route show table 100 | grep -q "^local default dev lo"'
check "fw4 table untouched" 'nft list table inet fw4 >/dev/null'

echo "== 4. dnsmasq"
check "dnsmasq forwards to xray first" 'uci get dhcp.@dnsmasq[0].server | grep -q "^127.0.0.1#5353"'
check "direct entries for relay names" 'test "$(uci get dhcp.@dnsmasq[0].server | tr " " "\n" | grep -c "^/")" -ge 1'
expect "noresolv set" "1" 'uci get dhcp.@dnsmasq[0].noresolv'
check "dnsmasq backup saved" 'test -s /etc/gatygo/dnsmasq.backup'

echo "== 5. cron"
check "cron line present" 'grep -q "# gatygo$" /etc/crontabs/root'
check "crond running" 'pgrep crond >/dev/null'

echo "== 6. unchanged update keeps the process"
P1=$(vm 'gatygo status | jq -r .pid')
vm 'gatygo update >/dev/null 2>&1'
expect "PID unchanged after an unchanged update" "$P1" 'gatygo status | jq -r .pid'
expect "result ok" "ok" 'gatygo status | jq -r .last_update.result'

echo "== 7. profile switch"
vm 'gatygo select "📍 Bravo" >/dev/null 2>&1; sleep 5'
P2=$(vm 'gatygo status | jq -r .pid')
[ -n "$P2" ] && [ "$P2" != "$P1" ] && ok "xray restarted on profile switch ($P1 -> $P2)" || bad "xray restarted on profile switch"
expect "profile_used updated" "📍 Bravo" 'gatygo status | jq -r .profile_used'
expect "Bravo config installed" "11" 'jq ".outbounds | length" /etc/gatygo/xray.json'

echo "== 8. LAN client (netns)"
vm 'ip netns add c1 && ip link add veth-c1 type veth peer name veth-c1p && ip link set veth-c1p netns c1 && ip link set veth-c1 master br-lan up &&
    ip netns exec c1 sh -c "ip link set lo up; ip addr add 192.168.1.50/24 dev veth-c1p; ip link set veth-c1p up; ip route add default via 192.168.1.1"'
check "client reaches the router" 'ip netns exec c1 ping -c1 -W2 192.168.1.1 >/dev/null'
dns_counter() { vm 'nft list chain inet gatygo dns_redirect | grep -o "packets [0-9]*" | tail -n1 | cut -d" " -f2'; }
tp_counter()  { vm 'nft list chain inet gatygo prerouting | grep -o "packets [0-9]*" | tail -n1 | cut -d" " -f2'; }
D0=$(dns_counter); vm 'ip netns exec c1 /tmp/tmo 3 nslookup example.com 8.8.8.8 >/dev/null 2>&1; true'; D1=$(dns_counter)
[ "${D1:-0}" -gt "${D0:-0}" ] && ok "DNS to 8.8.8.8 is redirected ($D0 -> $D1)" || bad "DNS to 8.8.8.8 is redirected ($D0 -> $D1)"
vm 'ip netns exec c1 /tmp/tmo 3 nslookup example.com 192.168.1.1 >/dev/null 2>&1; true'; D2=$(dns_counter)
[ "$D2" = "$D1" ] && ok "DNS to the router itself is not redirected" || bad "DNS to the router itself is not redirected ($D1 -> $D2)"
T0=$(tp_counter); vm 'ip netns exec c1 /tmp/tmo 3 nc 1.1.1.1 443 </dev/null >/dev/null 2>&1; true'; T1=$(tp_counter)
[ "${T1:-0}" -gt "${T0:-0}" ] && ok "TCP from the LAN hits tproxy ($T0 -> $T1)" || bad "TCP from the LAN hits tproxy ($T0 -> $T1)"

echo "== 9. stop cleans up"
vm '/etc/init.d/gatygo stop; sleep 2'
check "table removed" '! nft list table inet gatygo >/dev/null 2>&1'
check "policy rule removed" '! ip rule | grep -q "fwmark 0x1"'
check "cron line removed" '! grep -q "# gatygo$" /etc/crontabs/root'
check "dnsmasq restored" 'test -z "$(uci -q get dhcp.@dnsmasq[0].noresolv)" && ! test -e /etc/gatygo/dnsmasq.backup'
check "LAN client resolves via the router again" 'ip netns exec c1 /tmp/tmo 5 nslookup downloads.openwrt.org 192.168.1.1 >/dev/null 2>&1'

echo "== 10. start again, reboot"
vm '/etc/init.d/gatygo start; sleep 5'
expect "running after start" "true" 'gatygo status | jq -r .running'
vm 'reboot' >/dev/null 2>&1; sleep 5
ssh lab 'cd lab && ./openwrt.sh wait >/dev/null' && sleep 15
expect "running after reboot" "true" 'gatygo status | jq -r .running'
check "table present after reboot" 'nft list table inet gatygo >/dev/null'

echo "== 11. removal"
vm '/etc/init.d/gatygo stop; apk del gatygo >/dev/null 2>&1; true'
check "table gone after removal" '! nft list table inet gatygo >/dev/null 2>&1'
check "dnsmasq restored after removal" 'test -z "$(uci -q get dhcp.@dnsmasq[0].noresolv)"'

ssh lab 'pkill -f sub_server.py; true'
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
