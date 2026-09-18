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
# page scripts copied to the VM by hand would hide a file the package forgot
vm 'ip netns del c1 2>/dev/null; ip link del veth-c1 2>/dev/null; /etc/init.d/gatygo stop 2>/dev/null; apk del luci-app-gatygo gatygo >/dev/null 2>&1; rm -rf /etc/gatygo /var/run/gatygo /etc/config/gatygo /www/luci-static/resources/view/gatygo; true'
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
# the first start downloaded the core pinned in the package (about 20 MB from GitHub), checked and unpacked it
check "core: the pinned xray is in gatygo's own directory" '. /usr/lib/gatygo/core.sh && gatygo_core_ready'
expect "core: xray runs from there" "/usr/lib/gatygo/core/xray" 'readlink /proc/$(gatygo status | jq -r .pid)/exe'
expect "core: status reports the pinned version" "$(sed -n 's#.*  v\(.*\)/.*#\1#p' "$ROOT/gatygo/files/lib/core.pin" | head -n 1)" 'gatygo status | jq -r .xray_version'
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
check "gatygo nodes: api up, outbounds listed" 'gatygo nodes | jq -e ".api == true and (.nodes | length) >= 3 and .balancer == \"balancer\"" >/dev/null'
check "ubus log: text" 'ubus -S call gatygo log "{\"lines\":5}" | jq -e ".log | length > 0" >/dev/null'
expect "ubus update: started" "true" 'ubus -S call gatygo update | jq -r .started'
check "update finishes within 60 s" 'i=0; while gatygo updating && [ $i -lt 60 ]; do i=$((i+1)); sleep 1; done; ! gatygo updating'
expect "update result ok" "ok" 'gatygo status | jq -r .last_update.result'
check "check: probes go in through the tunnel's own inbound" 'gatygo check fresh | jq -e ".available == true and (.services | length) == 4 and (.services | map(.name) | join(\" \")) == \"YouTube Instagram Telegram WhatsApp\"" >/dev/null'
expect "check: a recent result is reused" "same" 'a=$(gatygo check | jq .time); sleep 1; b=$(ubus -S call gatygo check | jq .time); [ "$a" = "$b" ] && echo same'
# the mock panel is a private address: the fixture routes it direct, so an answer means the SOCKS handshake passed
check "check: the router's password opens the inbound" 'printf "proxy-user = \"gatygo:%s\"\n" "$(cat /etc/gatygo/check.secret)" | curl -K - -fs -o /dev/null -m 5 --socks5-hostname 127.0.0.1:10808 http://10.0.2.2:8787/log'
check "check: no way in without the password" '! curl -fs -o /dev/null -m 5 --socks5-hostname 127.0.0.1:10808 http://10.0.2.2:8787/log'
check "check: the password is kept 0600" 'test "$(ls -l /etc/gatygo/check.secret | cut -c1-10)" = -rw-------'
# the fixture's relays do not exist: what is checked is the run itself, a line for every country
check "ping: a run gives every country of the page a line" 'n=$(gatygo status | jq ".profiles | length"); gatygo ping | jq -e --argjson n "$n" ".measuring == false and .time > 0 and \$n > 0 and (.profiles | length) == \$n and (.profiles | all(has(\"ms\")))" >/dev/null'
expect "ping: ubus gives the kept result at once" "false true" 'n=$(gatygo status | jq ".profiles | length"); ubus -S call gatygo ping | jq -r --argjson n "$n" "\"\(.measuring) \((.profiles | length) == \$n)\""'
check "menu and acl installed" 'test -f /usr/share/luci/menu.d/luci-app-gatygo.json && test -f /usr/share/rpcd/acl.d/luci-app-gatygo.json'
check "LuCI serves the page after login" 'curl -s -c /tmp/ck -o /dev/null -d "luci_username=root&luci_password='"$LUCI_PASSWORD"'" http://127.0.0.1/cgi-bin/luci/ && curl -s -b /tmp/ck http://127.0.0.1/cgi-bin/luci/admin/services/gatygo | grep -q "gatygo/main"'
for v in main advanced; do
    expect "the package brings the $v page's script" "$(wc -c < "$ROOT/luci-app-gatygo/htdocs/luci-static/resources/view/gatygo/$v.js" | tr -d ' ')" "curl -s http://127.0.0.1/luci-static/resources/view/gatygo/$v.js | wc -c"
done
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
# 192.0.2.1 answers nobody: a connection means xray's local-only inbound took the packet from the nft rule
check "TCP from the LAN is accepted by xray" 'ip netns exec c1 curl -s -o /dev/null -m 4 -w "%{time_connect}" http://192.0.2.1/ | awk "{ exit !(\$1 > 0) }"'
check "the tproxy inbound cannot be reached directly from the LAN" '! ip netns exec c1 /tmp/tmo 3 nc 192.168.1.1 12345 </dev/null'

echo "== 8b. xray quits by itself"
# procd restarts it 5 times, 5 s apart, then gives up: the instance stays, not running
vm 'for i in 1 2 3 4 5 6 7; do p=$(gatygo status | jq -r .pid); [ -n "$p" ] && kill -9 "$p"; sleep 7; done'
expect "status tells a crash from a stop" "false 137" 'gatygo status | jq -r "\"\(.running) \(.crashed)\""'
vm '/etc/init.d/gatygo start; sleep 5'
expect "start brings it back" "true null" 'gatygo status | jq -r "\"\(.running) \(.crashed)\""'

echo "== 9. stop cleans up"
vm '/etc/init.d/gatygo stop; sleep 2'
expect "a stop is not a crash" "false null" 'gatygo status | jq -r "\"\(.running) \(.crashed)\""'
check "table removed" '! nft list table inet gatygo >/dev/null 2>&1'
check "policy rule removed" '! ip rule | grep -q "fwmark 0x1"'
check "cron line removed" '! grep -q "# gatygo$" /etc/crontabs/root'
check "dnsmasq restored" 'test -z "$(uci -q get dhcp.@dnsmasq[0].noresolv)" && ! test -e /etc/gatygo/dnsmasq.backup'
check "LAN client resolves via the router again" 'ip netns exec c1 /tmp/tmo 5 nslookup downloads.openwrt.org 192.168.1.1 >/dev/null 2>&1'
# Save & Apply (reload_config is what LuCI runs) with the VPN stopped by hand: the subscription is
# downloaded with the new settings, the VPN stays off
vm 'uci set gatygo.main.user_agent="gatygo/e2e-stopped"; uci commit gatygo; reload_config; sleep 12'
if ssh "$LAB_HOST" 'curl -s localhost:8787/log' | jq -e '[.[] | select(.headers["user-agent"] == "gatygo/e2e-stopped")] | length > 0' >/dev/null; then ok "settings applied while stopped refresh the subscription"; else bad "settings applied while stopped refresh the subscription"; fi
expect "and the VPN stays off" "false" 'gatygo status | jq -r .running'
check "with nothing of the tunnel back" '! nft list table inet gatygo >/dev/null 2>&1 && test -z "$(uci -q get dhcp.@dnsmasq[0].noresolv)"'
# switched off and on again in the settings is another matter: that starts it
vm 'uci delete gatygo.main.user_agent; uci set gatygo.main.enabled=0; uci commit gatygo; reload_config; sleep 4; uci set gatygo.main.enabled=1; uci commit gatygo; reload_config; sleep 12'
expect "enabling it in the settings starts it" "true" 'gatygo status | jq -r .running'
vm '/etc/init.d/gatygo stop; sleep 2'

echo "== 10. start again, reboot"
# the cached config needs geo files that are gone (as after a sysupgrade): start gets them first
vm 'rm -f /usr/share/xray/geosite.dat /usr/share/xray/geoip.dat; /etc/init.d/gatygo start; sleep 5'
expect "running after start" "true" 'gatygo status | jq -r .running'
check "start brought the missing geo files back" 'test -s /usr/share/xray/geosite.dat && test -s /usr/share/xray/geoip.dat'
vm 'reboot' >/dev/null 2>&1; sleep 5
ssh "$LAB_HOST" "cd $LAB_DIR && ./openwrt.sh wait >/dev/null" && sleep 15
expect "running after reboot" "true" 'gatygo status | jq -r .running'
expect "last update result survives the reboot" "ok" 'gatygo status | jq -r .last_update.result'
check "table present after reboot" 'nft list table inet gatygo >/dev/null'

echo "== 11. removal"
vm '/etc/init.d/gatygo stop; apk del luci-app-gatygo gatygo >/dev/null 2>&1; true'
check "core removed with the package" '! test -e /usr/lib/gatygo/core'
check "table gone after removal" '! nft list table inet gatygo >/dev/null 2>&1'
check "dnsmasq restored after removal" 'test -z "$(uci -q get dhcp.@dnsmasq[0].noresolv)"'
# the fixture geo files must not survive either: a real subscription would keep them (304 on the newer mtime)
vm 'rm -rf /etc/gatygo /var/run/gatygo /etc/config/gatygo /usr/share/xray/geosite.dat /usr/share/xray/geoip.dat; [ -f /root/gatygo.config.pre-e2e ] && mv /root/gatygo.config.pre-e2e /etc/config/gatygo; true'
check "no e2e state left behind" '! test -e /etc/gatygo && ! test -e /usr/share/xray/geosite.dat && test "$(uci -q get gatygo.main.profile)" != "📍 Bravo"'

ssh "$LAB_HOST" 'pkill -f sub_server.py; true'
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
