#!/bin/bash
# End-to-end check of the gatygo package on the lab VM. Run from the repo root:
#   tests/vm/run.sh [gatygo.apk]
# Needs: LAB_HOST, the ssh target of the machine running the OpenWrt VM, and LAB_DIR, a directory there
# (relative to the remote home or absolute) with openwrt.sh providing `wait` and `ssh [args] CMD`; the
# VM's ssh is forwarded to 127.0.0.1:2222 on that machine and reaches it as 10.0.2.2. The mock panel
# runs there with python3. FIXTURE defaults to tests/fixtures/subscription.json. LUCI_PASSWORD is the
# VM's root password for the LuCI login check (default: empty).
# The VM's /etc/config/gatygo from before the run (the lab may hold a real subscription) is put back
# at the end; everything the run created is removed.
set -u
: "${LAB_HOST:?set LAB_HOST to the ssh target of the lab host}" "${LAB_DIR:?set LAB_DIR to the lab directory there}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
APK=${1:-$(ls "$ROOT"/bin/packages/x86_64/gatygo/gatygo-*.apk 2>/dev/null | tail -n 1)}
FIXTURE=${FIXTURE:-$ROOT/tests/fixtures/subscription.json}
LUCI_PASSWORD=${LUCI_PASSWORD:-}
[ -f "$APK" ] || { echo "no .apk: build it with tools/build-apk.sh" >&2; exit 1; }
LUCI_APK=${LUCI_APK:-$(ls "$(dirname "$APK")"/luci-app-gatygo-*.apk 2>/dev/null | tail -n 1)}
[ -f "$LUCI_APK" ] || { echo "no luci-app-gatygo .apk next to $APK" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "no fixture at $FIXTURE" >&2; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }
# vm CMD — run CMD inside the OpenWrt VM (quoted once for the lab host shell)
vm()  { ssh "$LAB_HOST" "cd $LAB_DIR && ./openwrt.sh ssh -o BatchMode=yes $(printf '%q' "$1")"; }
# check MSG CMD — pass when CMD succeeds inside the VM
check() { if vm "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
# expect MSG EXPECTED CMD — pass when CMD's stdout inside the VM equals EXPECTED
expect() { local got; got=$(vm "$3" 2>/dev/null); if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 (got: $got)"; fi; }

echo "== 0. lab: mock panel + files"
scp -q "$APK" "$LAB_HOST:$LAB_DIR/gatygo.apk"
scp -q "$LUCI_APK" "$LAB_HOST:$LAB_DIR/luci-app-gatygo.apk"
scp -q "$FIXTURE" "$LAB_HOST:$LAB_DIR/fixture.json"
scp -q "$ROOT/tests/mock/sub_server.py" "$LAB_HOST:$LAB_DIR/sub_server.py"
ssh "$LAB_HOST" "mkdir -p $LAB_DIR/geo" && scp -q "$ROOT"/tests/fixtures/geo/*.dat "$LAB_HOST:$LAB_DIR/geo/"
ssh "$LAB_HOST" "cd $LAB_DIR && pkill -f sub_server.py; nohup python3 sub_server.py 8787 fixture.json geo http://10.0.2.2:8787 > mock.log 2>&1 &
             i=0; until curl -fs -o /dev/null localhost:8787/log; do i=\$((i + 1)); [ \$i -lt 20 ] || exit 1; sleep 0.5; done" \
    && ok "mock panel up on the lab host" || bad "mock panel"
# dropbear has no sftp server: force the legacy scp protocol
ssh "$LAB_HOST" "cd $LAB_DIR && ./openwrt.sh wait >/dev/null && scp -q -O -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR gatygo.apk luci-app-gatygo.apk root@127.0.0.1:/tmp/"
# the VM's busybox has no `timeout`: /tmp/tmo SECS CMD... runs CMD and kills it after SECS
vm 'printf "%s\n" "#!/bin/sh" "t=\$1; shift" "\"\$@\" & p=\$!" "( sleep \"\$t\"; kill \"\$p\" 2>/dev/null ) & w=\$!" "wait \"\$p\"; rc=\$?" "kill \"\$w\" 2>/dev/null" "exit \$rc" > /tmp/tmo && chmod +x /tmp/tmo'
check "tmo helper works" '/tmp/tmo 1 sleep 5; test $? -ne 0 && /tmp/tmo 3 true'

echo "== 1. install"
vm 'cp /etc/config/gatygo /root/gatygo.config.pre-e2e 2>/dev/null; true'
vm 'ip netns del c1 2>/dev/null; ip link del veth-c1 2>/dev/null; /etc/init.d/gatygo stop 2>/dev/null; apk del luci-app-gatygo gatygo >/dev/null 2>&1; rm -rf /etc/gatygo /var/run/gatygo /etc/config/gatygo; true'
# geo files of unknown origin with a fresh mtime must not block the first update (they got 304 and stayed)
vm 'mkdir -p /usr/share/xray; echo junk > /usr/share/xray/geosite.dat; echo junk > /usr/share/xray/geoip.dat'
check "apk installs" 'apk add --allow-untrusted /tmp/gatygo.apk >/dev/null 2>&1'
check "luci-app-gatygo installs" 'apk add --allow-untrusted /tmp/luci-app-gatygo.apk >/dev/null 2>&1'
expect "gatygo version" "$(sed -n 's/^PKG_VERSION:=//p' "$ROOT/gatygo/Makefile")" 'gatygo version'
check "init script enabled" 'test -e /etc/rc.d/S95gatygo'

echo "== 2. configure + start"
vm 'uci set gatygo.main.enabled=1; uci set gatygo.main.sub_url=http://10.0.2.2:8787/sub; uci commit gatygo'
check "start" '/etc/init.d/gatygo start && sleep 5'
expect "xray running" "true" 'gatygo status | jq -r .running'
expect "first balancer tile applied" "🌐 Auto" 'gatygo status | jq -r .profile_used'
expect "update result ok" "ok updated" 'gatygo status | jq -r "\"\(.last_update.result) \(.last_update.code)\""'
check "xray.json installed 0600" 'test "$(ls -l /etc/gatygo/xray.json | cut -c1-10)" = -rw-------'
check "geo files installed" 'test -s /usr/share/xray/geosite.dat && test -s /usr/share/xray/geoip.dat'
check "foreign geo files replaced" 'test "$(wc -c < /usr/share/xray/geosite.dat)" -gt 100 && test -s /etc/gatygo/geo-source.env'

echo "== 2b. LuCI and ubus"
check "ubus object registered" 'ubus list gatygo >/dev/null'
expect "ubus status: running" "true" 'ubus -S call gatygo status | jq -r .running'
expect "ubus status: configured, not updating" "true false" 'ubus -S call gatygo status | jq -r "\"\\(.configured) \\(.updating)\""'
check "ubus status: uptime and next update known" 'ubus -S call gatygo status | jq -e ".uptime >= 0 and .next_update > 0" >/dev/null'
expect "ubus status: 22 profiles, 13 balanced" "22 13" 'ubus -S call gatygo status | jq -r "\"\\(.profiles | length) \\([.profiles[] | select(.balanced)] | length)\""'
check "ubus nodes: api up, outbounds listed" 'ubus -S call gatygo nodes | jq -e ".api == true and (.nodes | length) >= 3 and .balancer == \"balancer\"" >/dev/null'
check "ubus log: text" 'ubus -S call gatygo log "{\"lines\":5}" | jq -e ".log | length > 0" >/dev/null'
expect "ubus update: started" "true" 'ubus -S call gatygo update | jq -r .started'
check "update finishes within 60 s" 'i=0; while gatygo updating && [ $i -lt 60 ]; do i=$((i+1)); sleep 1; done; ! gatygo updating'
expect "update result ok" "ok" 'gatygo status | jq -r .last_update.result'
check "menu and acl installed" 'test -f /usr/share/luci/menu.d/luci-app-gatygo.json && test -f /usr/share/rpcd/acl.d/luci-app-gatygo.json'
check "LuCI serves the page after login" 'curl -s -c /tmp/ck -o /dev/null -d "luci_username=root&luci_password='"$LUCI_PASSWORD"'" http://127.0.0.1/cgi-bin/luci/ && curl -s -b /tmp/ck http://127.0.0.1/cgi-bin/luci/admin/services/gatygo | grep -q "gatygo/main"'
check "LuCI serves the Advanced page" 'curl -s -b /tmp/ck http://127.0.0.1/cgi-bin/luci/admin/services/gatygo/advanced | grep -q "gatygo/advanced"'

echo "== 2c. settings reload"
vm 'uci set gatygo.main.user_agent="gatygo/e2e"; uci commit gatygo; /etc/init.d/gatygo reload; sleep 10'
if ssh "$LAB_HOST" 'curl -s localhost:8787/log' | jq -e '[.[] | select(.headers["user-agent"] == "gatygo/e2e")] | length > 0' >/dev/null; then ok "reload re-downloads with the new user agent"; else bad "reload re-downloads with the new user agent"; fi
expect "still running after reload" "true" 'gatygo status | jq -r .running'
vm 'uci delete gatygo.main.user_agent; uci commit gatygo; /etc/init.d/gatygo reload; sleep 10'

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
vm 'uci set gatygo.main.sub_url=http://10.0.2.2:8787/sub-broken; uci commit gatygo; gatygo update >/dev/null 2>&1; uci set gatygo.main.sub_url=http://10.0.2.2:8787/sub; uci commit gatygo'
expect "a failed update names its cause and keeps the profile in use" "error fetch_failed 📍 Bravo" 'gatygo status | jq -r "\"\(.last_update.result) \(.last_update.code) \(.profile_used)\""'
vm 'gatygo update >/dev/null 2>&1'

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
ssh "$LAB_HOST" "cd $LAB_DIR && ./openwrt.sh wait >/dev/null" && sleep 15
expect "running after reboot" "true" 'gatygo status | jq -r .running'
expect "last update result survives the reboot" "ok" 'gatygo status | jq -r .last_update.result'
check "table present after reboot" 'nft list table inet gatygo >/dev/null'

echo "== 11. removal"
vm '/etc/init.d/gatygo stop; apk del luci-app-gatygo gatygo >/dev/null 2>&1; true'
check "table gone after removal" '! nft list table inet gatygo >/dev/null 2>&1'
check "dnsmasq restored after removal" 'test -z "$(uci -q get dhcp.@dnsmasq[0].noresolv)"'
# the fixture geo files must not survive either: a real subscription would keep them (304 on the newer mtime)
vm 'rm -rf /etc/gatygo /var/run/gatygo /etc/config/gatygo /usr/share/xray/geosite.dat /usr/share/xray/geoip.dat; [ -f /root/gatygo.config.pre-e2e ] && mv /root/gatygo.config.pre-e2e /etc/config/gatygo; true'
check "no e2e state left behind" '! test -e /etc/gatygo && ! test -e /usr/share/xray/geosite.dat && test "$(uci -q get gatygo.main.profile)" != "📍 Bravo"'

ssh "$LAB_HOST" 'pkill -f sub_server.py; true'
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
