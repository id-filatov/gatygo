#!/bin/bash
# End-to-end check of the upgrade from the page on the lab VM. Run from the repo root:
#   tests/vm/upgrade.sh DIR
# DIR holds four package sets, each with gatygo-*.apk and luci-app-gatygo-*.apk:
#   v1, v2         two versions of the same tree (v2 the later one)
#   v2-badconfig   v2 whose config fails `xray -test`
#   v2-badcore     v2 pinning an xray core that answers `version` and `run -test` but does not run
# A set may also hold the core.pin it was built with (served as the tag's raw file; default:
# gatygo/files/lib/core.pin) and core/ (served as the XTLS release, GATYGO_CORE_BASE).
# LAB_HOST, LAB_DIR, FIXTURE and LUCI_PASSWORD as for tests/vm/run.sh. The lab host serves the
# releases (GitHub's stand-in) on port 8790 and the mock panel on 8787. The VM's gatygo settings,
# state and geo files from before the run are put back at the end; KEEP=1 leaves v1 with the mock
# subscription, the release server and the release_* options in place instead (to try the page).
set -u
: "${LAB_HOST:?set LAB_HOST to the ssh target of the lab host}" "${LAB_DIR:?set LAB_DIR to the lab directory there}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DIR=${1:?usage: tests/vm/upgrade.sh DIR}
FIXTURE=${FIXTURE:-$ROOT/tests/fixtures/subscription.json}
LUCI_PASSWORD=${LUCI_PASSWORD:-}
KEEP=${KEEP:-0}
for s in v1 v2 v2-badconfig v2-badcore; do
    ls "$DIR/$s"/gatygo-[0-9]*.apk "$DIR/$s"/luci-app-gatygo-[0-9]*.apk >/dev/null 2>&1 || { echo "no packages in $DIR/$s" >&2; exit 1; }
done
_ver() { basename "$(ls "$DIR/$1"/gatygo-[0-9]*.apk)" | sed 's/^gatygo-\(.*\)-r[0-9]*\.apk$/\1/'; }
V1=$(_ver v1) V2=$(_ver v2)

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }
# vm CMD — run CMD inside the OpenWrt VM (quoted once for the lab host shell)
vm()  { ssh "$LAB_HOST" "cd $LAB_DIR && ./openwrt.sh ssh -o BatchMode=yes $(printf '%q' "$1")"; }
# check MSG CMD — pass when CMD succeeds inside the VM
check() { if vm "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
# expect MSG EXPECTED CMD — pass when CMD's stdout inside the VM equals EXPECTED
expect() { local got; got=$(vm "$3" 2>/dev/null); if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 (got: $got)"; fi; }

# serve SET — the release server answers for SET as the latest release, v1 as the installed one
serve() {
    local www; www=$(mktemp -d)
    mkdir -p "$www/releases/tags" "$www/assets" "$www/raw/v$V2/gatygo/files/lib" "$www/core"
    cp "$DIR/v1"/*.apk "$DIR/$1"/*.apk "$www/assets/"
    cp "$DIR/$1/core.pin" "$www/raw/v$V2/gatygo/files/lib/core.pin" 2>/dev/null || cp "$ROOT/gatygo/files/lib/core.pin" "$www/raw/v$V2/gatygo/files/lib/core.pin"
    [ -d "$DIR/$1/core" ] && cp -R "$DIR/$1/core/." "$www/core/"
    python3 - "$www" "$V1" "$DIR/v1" "$V2" "$DIR/$1" <<'EOF'
import glob, hashlib, json, os, sys
www = sys.argv[1]
def release(v, d):
    assets = []
    for f in sorted(glob.glob(os.path.join(d, "*.apk"))):
        n = os.path.basename(f)
        assets.append({"name": n, "browser_download_url": "http://10.0.2.2:8790/assets/" + n,
                       "digest": "sha256:" + hashlib.sha256(open(f, "rb").read()).hexdigest()})
    return {"tag_name": "v" + v, "draft": False, "prerelease": False, "assets": assets}
json.dump(release(sys.argv[2], sys.argv[3]), open(os.path.join(www, "releases/tags/v" + sys.argv[2]), "w"))
json.dump(release(sys.argv[4], sys.argv[5]), open(os.path.join(www, "releases/latest"), "w"))
EOF
    rsync -a --delete "$www/" "$LAB_HOST:$LAB_DIR/upgrade/www/"
    rm -rf "$www"
}

# v1 — v1 installed again, the VPN running, no upgrade left over
v1() {
    vm 'apk add --allow-untrusted /tmp/up/v1/*.apk >/dev/null 2>&1; rm -f /var/run/gatygo/upgrade.json; rm -rf /usr/lib/gatygo/core.prev
        /etc/init.d/gatygo start >/dev/null 2>&1; i=0; until [ "$(gatygo status | jq -r .running)" = true ] || [ $i -ge 30 ]; do i=$((i + 1)); sleep 1; done'
    expect "v1 in place and running" "$V1 true" 'echo "$(gatygo version) $(gatygo status | jq -r .running)"'
}

# upgrade — the upgrade as the page starts it, waited for; then its outcome
upgrade() { vm 'GATYGO_CORE_BASE=http://10.0.2.2:8790/core /tmp/tmo 300 gatygo upgrade run' >/dev/null 2>&1; }
OUTCOME='jq -r "\"\(.state) \(.code) \(.rolled_back) \(.steps.core)\"" /var/run/gatygo/upgrade.json'
STATE='sha256sum /etc/gatygo/* | sort -k2'
CORE='sha256sum /usr/lib/gatygo/core/xray /usr/lib/gatygo/core/pin'

echo "== 0. lab: releases, mock panel, packages"
ssh "$LAB_HOST" "mkdir -p $LAB_DIR/upgrade/www $LAB_DIR/upgrade/sets $LAB_DIR/geo"
scp -q "$FIXTURE" "$LAB_HOST:$LAB_DIR/fixture.json"
scp -q "$ROOT/tests/mock/sub_server.py" "$LAB_HOST:$LAB_DIR/sub_server.py"
scp -q "$ROOT"/tests/fixtures/geo/*.dat "$LAB_HOST:$LAB_DIR/geo/"
for s in v1 v2 v2-badconfig v2-badcore; do
    ssh "$LAB_HOST" "rm -rf $LAB_DIR/upgrade/sets/$s; mkdir -p $LAB_DIR/upgrade/sets/$s" && scp -q "$DIR/$s"/*.apk "$LAB_HOST:$LAB_DIR/upgrade/sets/$s/"
done
serve v2
ssh "$LAB_HOST" "cd $LAB_DIR && pkill -f sub_server.py; pkill -f 'http.server 8790'
             nohup python3 sub_server.py 8787 fixture.json geo http://10.0.2.2:8787 > mock.log 2>&1 &
             nohup python3 -m http.server 8790 --directory upgrade/www > upgrade/http.log 2>&1 &
             i=0; until curl -fs -o /dev/null localhost:8787/log && curl -fs -o /dev/null localhost:8790/releases/latest; do i=\$((i + 1)); [ \$i -lt 20 ] || exit 1; sleep 0.5; done" \
    && ok "mock panel and release server up on the lab host" || bad "mock panel and release server"
# dropbear has no sftp server: force the legacy scp protocol
ssh "$LAB_HOST" "cd $LAB_DIR && ./openwrt.sh wait >/dev/null && cd upgrade/sets && scp -q -O -r -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR v1 v2 v2-badconfig v2-badcore root@127.0.0.1:/tmp/" \
    && vm 'rm -rf /tmp/up && mkdir /tmp/up && mv /tmp/v1 /tmp/v2 /tmp/v2-badconfig /tmp/v2-badcore /tmp/up/'
# the VM's busybox has no `timeout`: /tmp/tmo SECS CMD... runs CMD and kills it after SECS
vm 'printf "%s\n" "#!/bin/sh" "t=\$1; shift" "\"\$@\" & p=\$!" "( sleep \"\$t\"; kill \"\$p\" 2>/dev/null ) & w=\$!" "wait \"\$p\"; rc=\$?" "kill \"\$w\" 2>/dev/null" "exit \$rc" > /tmp/tmo && chmod +x /tmp/tmo'
check "packages on the VM" 'test "$(ls /tmp/up/*/*.apk | wc -l)" = 8'

echo "== 1. v1 on the mock subscription"
# what the lab had, put back at the end (in RAM: flash is what the checks measure)
vm 'mkdir -p /tmp/up-pre; [ -e /tmp/up-pre/config ] || { cp /etc/config/gatygo /tmp/up-pre/config; cp -a /etc/gatygo /tmp/up-pre/state
        mkdir -p /tmp/up-pre/geo; cp -p /usr/share/xray/geosite.dat /usr/share/xray/geoip.dat /tmp/up-pre/geo/ 2>/dev/null; }; true'
vm '/etc/init.d/gatygo stop >/dev/null 2>&1; apk add --allow-untrusted /tmp/up/v1/*.apk >/dev/null 2>&1; rm -rf /etc/gatygo/* /var/run/gatygo/upgrade*
    cp /usr/lib/gatygo/defaults.config /etc/config/gatygo
    uci set gatygo.main.enabled=1; uci set gatygo.main.sub_url=http://10.0.2.2:8787/sub
    uci set gatygo.main.release_api=http://10.0.2.2:8790/releases; uci set gatygo.main.release_raw=http://10.0.2.2:8790/raw
    uci add gatygo rule >/dev/null; uci set gatygo.@rule[-1].domain=rare.example; uci set gatygo.@rule[-1].to=direct; uci commit gatygo'
v1
expect "the check finds v2" "$V2 true" 'gatygo upgrade check; ubus -S call gatygo status | jq -r "\"\(.upgrade.latest) \(.upgrade.available)\""'

echo "== 2. success: the same core, the same config"
_pid=$(vm 'gatygo status | jq -r .pid'); _conf=$(vm 'sha256sum /etc/config/gatygo /etc/gatygo/profile /etc/gatygo/rules.json')
upgrade
expect "outcome ok, core unchanged" "ok  false skip" "$OUTCOME"
expect "v2 installed" "$V2" 'gatygo version'
expect "running" "true" 'gatygo status | jq -r .running'
expect "xray not restarted: the VPN did not blink" "$_pid" 'gatygo status | jq -r .pid'
expect "settings, country and my rules as before" "$_conf" 'sha256sum /etc/config/gatygo /etc/gatygo/profile /etc/gatygo/rules.json'
check "the old core's link is gone" '! test -e /usr/lib/gatygo/core.prev'
expect "the page now has nothing newer" "false" 'ubus -S call gatygo status | jq -r .upgrade.available'

echo "== 3. a VPN stopped by hand"
v1
vm 'gatygo stop >/dev/null 2>&1'
upgrade
expect "outcome ok" "ok" 'jq -r .state /var/run/gatygo/upgrade.json'
expect "v2, still stopped" "$V2 false" 'echo "$(gatygo version) $(gatygo status | jq -r .running)"'
check "the stop flag stays" 'test -e /var/run/gatygo/stopped'

echo "== 4. no room on the flash"
v1
_state=$(vm "$STATE"); _core=$(vm "$CORE"); _apkdb=$(vm 'date -r /lib/apk/db/installed +%s')
vm 'f=$(df -k /overlay | awk "END { print \$(NF - 2) }"); dd if=/dev/zero of=/overlay/up-fill bs=1024 count=$((f - 1024)) 2>/dev/null; true'
upgrade
expect "outcome no_space" "failed no_space false todo" "$OUTCOME"
vm 'rm -f /overlay/up-fill'
expect "v1 stays" "$V1" 'gatygo version'
expect "the state dir untouched" "$_state" "$STATE"
expect "the core untouched" "$_core" "$CORE"
expect "apk installed nothing" "$_apkdb" 'date -r /lib/apk/db/installed +%s'

echo "== 5. the new version's config fails xray -test"
serve v2-badconfig
v1
_state=$(vm "$STATE")
upgrade
expect "outcome config_failed, rolled back" "failed config_failed true skip" "$OUTCOME"
expect "v1 back" "$V1" 'gatygo version'
expect "the state dir byte for byte as before" "$_state" "$STATE"
expect "running" "true" 'gatygo status | jq -r .running'
check "LuCI serves the page" 'curl -s -c /tmp/ck -o /dev/null -d "luci_username=root&luci_password='"$LUCI_PASSWORD"'" http://127.0.0.1/cgi-bin/luci/ && test "$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/ck http://127.0.0.1/cgi-bin/luci/admin/services/gatygo)" = 200'

echo "== 6. the new version pins a core that does not run"
serve v2-badcore
v1
_core=$(vm "$CORE")
upgrade
expect "outcome not_started, rolled back" "failed not_started true ok" "$OUTCOME"
expect "v1 back" "$V1" 'gatygo version'
expect "the old core byte for byte" "$_core" "$CORE"
check "running again" 'i=0; until [ "$(gatygo status | jq -r .running)" = true ] || [ $i -ge 30 ]; do i=$((i + 1)); sleep 1; done; [ "$(gatygo status | jq -r .running)" = true ]'
check "the tunnel answers" 'gatygo check fresh | jq -e ".available == true" >/dev/null'

echo "== 7. two starts from the page"
serve v2
v1
expect "the first starts, the second is refused" "true false" 'a=$(ubus -S call gatygo upgrade "{\"action\":\"start\"}" | jq -r .started); b=$(ubus -S call gatygo upgrade "{\"action\":\"start\"}" | jq -r .started); echo "$a $b"'
check "the run ends" 'i=0; while gatygo upgrade running && [ $i -lt 240 ]; do i=$((i + 1)); sleep 1; done; ! gatygo upgrade running'
expect "started by rpcd, it outlived rpcd's restart: v2 installed" "ok $V2" 'echo "$(jq -r .state /var/run/gatygo/upgrade.json) $(gatygo version)"'

echo "== 8. clean-up"
check "no executor copies left in /tmp" '! ls -d /tmp/gatygo-upgrade.* >/dev/null 2>&1'
check "no locks left" '! ls -d /var/run/gatygo/*.lock >/dev/null 2>&1'
if [ "$KEEP" = 1 ]; then
    v1
    echo "== KEEP=1: v1 on the mock subscription, the release server on the lab host (port 8790) and release_* stay"
else
    vm '/etc/init.d/gatygo stop >/dev/null 2>&1; rm -rf /etc/gatygo/* /var/run/gatygo/upgrade* /tmp/up /tmp/tmo /tmp/ck
        cp /tmp/up-pre/config /etc/config/gatygo; cp -a /tmp/up-pre/state/. /etc/gatygo/; cp -p /tmp/up-pre/geo/* /usr/share/xray/ 2>/dev/null
        rm -rf /tmp/up-pre; true'
    check "the lab's own settings are back" '! uci -q get gatygo.main.release_api && test "$(uci -q get gatygo.main.sub_url)" != http://10.0.2.2:8787/sub'
    ssh "$LAB_HOST" "pkill -f sub_server.py; pkill -f 'http.server 8790'; rm -rf $LAB_DIR/upgrade; true"
fi
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
