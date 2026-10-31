#!/bin/sh
# An upgrade from the page, step by step: the progress file, the router's checks, the download
# of both versions. GitHub is a local http.server, apk a stub. Every case runs in a subshell
# with a fresh run dir and work dir and prints what the assertions compare.
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state" GATYGO_RUN="$tmp/run" GATYGO_CORE_DIR="$tmp/core"
export APK_STUB_LOG="$tmp/apk.log"
mkdir -p "$GATYGO_STATE" "$GATYGO_RUN" "$GATYGO_CORE_DIR"
: > "$UCI_STUB_FILE"; : > "$SYSLOG_STUB_FILE"; : > "$APK_STUB_LOG"
cp -a "$GATYGO_LIB" "$tmp/lib"
echo 20261027.1753 > "$tmp/lib/version"
export GATYGO_LIB="$tmp/lib"
. "$GATYGO_LIB/upgrade.sh"
gatygo_load_config

# _sysroot RELEASE ARCH — a fresh fake root with this openwrt_release
_sysroot() {
    GATYGO_SYSROOT=$(mktemp -d); mkdir -p "$GATYGO_SYSROOT/etc"
    printf "DISTRIB_RELEASE='%s'\nDISTRIB_ARCH='%s'\n" "$1" "$2" > "$GATYGO_SYSROOT/etc/openwrt_release"
}
_sysroot 25.12.5 aarch64_generic
export GATYGO_SYSROOT

# the router's free space: the tests say how much
gatygo_upgrade_free_kb() {
    case $1 in /tmp) echo "${FREE_TMP_KB:-999999}" ;; *) echo "${FREE_KB:-999999}" ;; esac
}

# --- GitHub: the latest release, the installed one, the assets, the new version's core.pin
www=$tmp/www
mkdir -p "$www/releases/tags" "$www/assets" "$www/raw/v20261105.1200/gatygo/files/lib"
for _v in 20261105.1200 20261027.1753; do
    for _p in gatygo luci-app-gatygo; do echo "$_p $_v" > "$www/assets/$_p-$_v-r1.apk"; done
done
_sha() { sha256sum < "$1" | cut -d' ' -f1; }
# _release FILE V GATYGO_DIGEST — a GitHub release of V, luci asset first, no digest for luci
_release() {
    jq -n --arg v "$2" --arg digest "$3" '
        {tag_name: "v\($v)", draft: false, prerelease: false,
         assets: [{name: "luci-app-gatygo-\($v)-r1.apk",
                   browser_download_url: "http://127.0.0.1:8793/assets/luci-app-gatygo-\($v)-r1.apk"},
                  {name: "gatygo-\($v)-r1.apk", digest: $digest,
                   browser_download_url: "http://127.0.0.1:8793/assets/gatygo-\($v)-r1.apk"}]}' > "$1"
}
_latest_ok() { _release "$www/releases/latest" 20261105.1200 "sha256:$(_sha "$www/assets/gatygo-20261105.1200-r1.apk")"; }
_latest_ok
_release "$www/releases/tags/v20261027.1753" 20261027.1753 ""
NEWPIN="1111111111111111111111111111111111111111111111111111111111111111  v26.10.1/Xray-linux-arm64-v8a.zip"
printf '# test pin\n%s\n' "$NEWPIN" > "$www/raw/v20261105.1200/gatygo/files/lib/core.pin"
echo "2222222222222222222222222222222222222222222222222222222222222222  v26.9.9/Xray-linux-arm64-v8a.zip" > "$GATYGO_CORE_DIR/pin"

python3 -m http.server 8793 --bind 127.0.0.1 --directory "$www" >/dev/null 2>&1 &
_srv=$!
for _ in $(seq 1 50); do curl -fs -o /dev/null http://127.0.0.1:8793/releases/latest && break; sleep 0.1; done
uci set gatygo.main.release_api=http://127.0.0.1:8793/releases
uci set gatygo.main.release_raw=http://127.0.0.1:8793/raw

# _fresh — a new run dir and work dir for one case (call inside the case's subshell)
_fresh() { GATYGO_RUN=$(mktemp -d); WORK=$(mktemp -d); }
_j() { jq -c "$1" "$GATYGO_RUN/upgrade.json"; }
# _pre — begin and run the router's checks; prints "<exit> <check> <code> <args>"
_pre() {
    gatygo_upgrade_begin 20261027.1753 20261105.1200
    gatygo_upgrade_preflight "$WORK" >/dev/null 2>&1
    echo "$? $(_j .steps.check) $(_j .code) $(_j .args)"
}

# --- the progress file
_r=$(_fresh
    gatygo_upgrade_begin 20261027.1753 20261105.1200
    _j '[.state, .from, .to, .steps.check, .steps.download, .code, .args, .rolled_back, (.time | type)]'
    gatygo_upgrade_mark check ok
    _j '[.steps.check, .steps.download, .steps.install]'
    gatygo_upgrade_mark download skip
    _j '[.steps.download, .steps.install]'
    gatygo_upgrade_set_to 20261106.0000
    _j .to
    gatygo_upgrade_fail no_space 40 29 2>/dev/null
    _j '[.state, .from, .to, .steps.install, .steps.core, .code, .args]')
assert_eq '["running","20261027.1753","20261105.1200","now","todo","",[],false,"number"]
["ok","now","todo"]
["skip","now"]
"20261106.0000"
["failed","20261027.1753","20261106.0000","fail","todo","no_space",["40","29"]]' "$_r" "begin, mark, set_to, fail"
_r=$(_fresh; gatygo_upgrade_begin 20261027.1753 20261105.1200; gatygo_upgrade_finish 2>/dev/null; _j .state)
assert_eq '"ok"' "$_r" "finish"

# --- all good: the checks pass, both versions are downloaded, the new one is simulated once
_r=$(_fresh
    : > "$APK_STUB_LOG"
    _pre
    echo "$_gatygo_up_new $_gatygo_up_core"
    gatygo_upgrade_download "$WORK" >/dev/null 2>&1
    echo "$? $(_j .steps.download) $(_j .steps.install)"
    echo $(ls "$WORK/new") / $(ls "$WORK/old")
    cat "$WORK/new/gatygo.apk" "$WORK/old/luci-app-gatygo.apk"
    grep -c -- '^add --simulate' "$APK_STUB_LOG")
assert_eq '0 "ok" "" []
20261105.1200 1
0 "ok" "now"
gatygo.apk luci-app-gatygo.apk / gatygo.apk luci-app-gatygo.apk
gatygo 20261105.1200
luci-app-gatygo 20261027.1753
1' "$_r" "all good"

# --- the checks, one refusal each
_r=$(_fresh; sleep 30 & _s=$!; mkdir -p "$GATYGO_RUN/update.lock"; echo "$_s" > "$GATYGO_RUN/update.lock/pid"
    _pre; kill "$_s")
assert_eq '1 "fail" "busy" []' "$_r" "another action holds the update lock"

_release "$www/releases/latest" 20261027.1753 ""
assert_eq '1 "fail" "no_release" []' "$(_fresh; _pre)" "nothing newer on GitHub"
_latest_ok

mv "$www/releases/tags/v20261027.1753" "$tmp/tag.json"
assert_eq '1 "fail" "no_rollback" []' "$(_fresh; _pre)" "the installed version is not on GitHub"
mv "$tmp/tag.json" "$www/releases/tags/v20261027.1753"

uci set gatygo.main.release_api=http://127.0.0.1:1/releases
assert_eq '1 "fail" "no_release" []' "$(_fresh; _pre)" "GitHub does not answer"
uci set gatygo.main.release_api=http://127.0.0.1:8793/releases

assert_eq '1 "fail" "openwrt" ["24.10.2"]' "$(_fresh; _sysroot 24.10.2 aarch64_generic; _pre)" "OpenWrt 24.10"
assert_eq '1 "fail" "openwrt" ["unknown"]' "$(_fresh; GATYGO_SYSROOT=$tmp/nowhere; _pre)" "no openwrt_release"
assert_eq '1 "fail" "conflict" ["luci-app-openclash"]' \
    "$(_fresh; APK_STUB_INSTALLED_PKGS="luci-app-openclash luci-base"; export APK_STUB_INSTALLED_PKGS; _pre)" "a conflicting package"
assert_eq '1 "fail" "no_core" []' "$(_fresh; _sysroot 25.12.5 powerpc_8548; _pre)" "no xray core for the processor"
assert_eq '1 "fail" "no_space" ["40","29"]' "$(_fresh; FREE_KB=30000; _pre)" "too little flash for a new core"
assert_eq '0 "ok" "" [] 0' "$(_fresh; FREE_KB=3000; echo "$NEWPIN" > "$GATYGO_CORE_DIR/pin"; _pre > "$WORK/pre.out"; echo "$(cat "$WORK/pre.out") $_gatygo_up_core")" \
    "the same core: 2 MB of flash are enough"
echo "2222222222222222222222222222222222222222222222222222222222222222  v26.9.9/Xray-linux-arm64-v8a.zip" > "$GATYGO_CORE_DIR/pin"
assert_eq '1 "fail" "no_space" ["2","1"]' "$(_fresh; FREE_KB=1500; echo "$NEWPIN" > "$GATYGO_CORE_DIR/pin"; _pre)" "the same core: less than 2 MB"
echo "2222222222222222222222222222222222222222222222222222222222222222  v26.9.9/Xray-linux-arm64-v8a.zip" > "$GATYGO_CORE_DIR/pin"
assert_eq '1 "fail" "no_memory" ["30","19"]' "$(_fresh; FREE_TMP_KB=20000; _pre)" "too little memory for a new core"

# --- the download
_release "$www/releases/latest" 20261105.1200 "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_r=$(_fresh; _pre >/dev/null; gatygo_upgrade_download "$WORK" >/dev/null 2>&1
    echo "$? $(_j .steps.check) $(_j .steps.download) $(_j .code)")
assert_eq '1 "ok" "fail" "checksum"' "$_r" "a damaged file"
_latest_ok

mv "$www/assets/luci-app-gatygo-20261027.1753-r1.apk" "$tmp/old-luci.apk"
_r=$(_fresh; _pre >/dev/null; gatygo_upgrade_download "$WORK" >/dev/null 2>&1; echo "$? $(_j .steps.download) $(_j .code)")
assert_eq '1 "fail" "download_failed"' "$_r" "a package is not there"
mv "$tmp/old-luci.apk" "$www/assets/luci-app-gatygo-20261027.1753-r1.apk"

_r=$(_fresh; _pre >/dev/null
    APK_STUB_SIMULATE_RC=1 APK_STUB_SIMULATE_OUT="ERROR: unable to select packages:
  kmod-nft-foo (no such package):
    required by: gatygo-20261105.1200-r1[kmod-nft-foo]
  libfoo2 (no such package):
    required by: gatygo-20261105.1200-r1[libfoo2]"
    export APK_STUB_SIMULATE_RC APK_STUB_SIMULATE_OUT
    gatygo_upgrade_download "$WORK" >/dev/null 2>&1; echo "$? $(_j .steps.download) $(_j .code) $(_j .args)")
assert_eq '1 "fail" "deps" ["kmod-nft-foo libfoo2"]' "$_r" "the feeds miss a dependency"
_r=$(_fresh; _pre >/dev/null; APK_STUB_SIMULATE_RC=1 gatygo_upgrade_download "$WORK" >/dev/null 2>&1; echo "$(_j .code) $(_j .args)")
assert_eq '"deps" [""]' "$_r" "the feeds refuse without naming a package"

# the feeds' index lives in tmpfs (gone after a reboot): it is fetched before apk resolves anything
_r=$(_fresh; : > "$APK_STUB_LOG"; _pre >/dev/null; gatygo_upgrade_download "$WORK" >/dev/null 2>&1
    grep -E '^(update|add --simulate)' "$APK_STUB_LOG" | cut -d' ' -f1-2 | tr '\n' ','; echo)
assert_eq "update,add --simulate," "$_r" "the feeds' index is fetched before the simulation"
_r=$(_fresh; _pre >/dev/null; APK_STUB_UPDATE_RC=1 gatygo_upgrade_download "$WORK" >/dev/null 2>&1; echo "$? $(_j .steps.download)")
assert_eq '0 "ok"' "$_r" "an index that does not come is not a refusal by itself"
# df answering something else than a number refuses, it does not kill the run
assert_eq '1 "fail" "no_space" ["40","0"]' "$(_fresh; FREE_KB='12%'; _pre)" "free space that is not a number"

# --- nothing was installed by any of the above
assert_exit 0 "the simulations are in the apk log" grep -q -- '^add --simulate' "$APK_STUB_LOG"
assert_eq "0" "$(grep '^add' "$APK_STUB_LOG" | grep -vc -- '--simulate')" "apk add only ever simulated"


# === install, core, rebuild, roll back
export GATYGO_UPGRADE_TARGET="$tmp/newlib" GATYGO_BIN=/src/tests/stubs/gatygo-cli GATYGO_INIT=/src/tests/stubs/gatygo-init
export GATYGO_CLI_LOG="$tmp/cli.log" GATYGO_INIT_LOG="$tmp/init.log" APK_STUB_ADDED="$tmp/added" GATYGO_UPGRADE_SETTLE=0
mkdir -p "$GATYGO_UPGRADE_TARGET"
echo 20261105.1200 > "$GATYGO_UPGRADE_TARGET/version"
# the new version's core.sh: FAKE_CORE says what gatygo_core_ensure did; a new core replaces the
# file (a new inode, as the real one does with xray.new)
cat > "$GATYGO_UPGRADE_TARGET/core.sh" <<'EOF'
gatygo_core_ensure() {
    case ${FAKE_CORE:-ready} in
        none) return 1 ;;
        installed) echo new > "$GATYGO_CORE_DIR/xray.new"; mv "$GATYGO_CORE_DIR/xray.new" "$GATYGO_CORE_DIR/xray"
            echo newpin > "$GATYGO_CORE_DIR/pin" ;;
    esac
    echo "${FAKE_CORE:-ready}"
}
EOF
# xray as procd reports it: RUNNING (default 1); with PID_FILE the pid changes on every look
gatygo_xray_running() { [ "${RUNNING:-1}" = 1 ]; }
gatygo_xray_pid() {
    [ -n "${PID_FILE:-}" ] || { echo 4242; return; }
    _n=$(cat "$PID_FILE" 2>/dev/null || echo 100); echo $((_n + 1)) > "$PID_FILE"; echo "$_n"
}
# _setup — the router before the upgrade: old core and pin, old config, empty logs
_setup() {
    GATYGO_RUN=$(mktemp -d)
    rm -rf "$GATYGO_STATE" "$GATYGO_CORE_DIR" "$GATYGO_CORE_DIR.prev"
    mkdir -p "$GATYGO_STATE" "$GATYGO_CORE_DIR"
    echo '{"v":"old"}' > "$GATYGO_STATE/xray.json"
    echo '{"sub":"cached"}' > "$GATYGO_STATE/subscription.json"
    echo '{"checked":1,"version":"20261105.1200"}' > "$GATYGO_STATE/upgrade-latest.json"
    echo old > "$GATYGO_CORE_DIR/xray"; echo oldpin > "$GATYGO_CORE_DIR/pin"
    : > "$APK_STUB_LOG"; : > "$APK_STUB_ADDED"; : > "$GATYGO_INIT_LOG"; : > "$GATYGO_CLI_LOG"
}
# _run — the whole upgrade; prints "<exit> <state> <code> <rolled_back> <core step> <restart step>"
_run() {
    gatygo_upgrade_run >/dev/null 2>&1
    echo "$? $(_j .state) $(_j .code) $(_j .rolled_back) $(_j .steps.core) $(_j .steps.restart)"
}
_added() { sed -n "s#.*/\($1\)/\(.*\)#\1/\2#p" "$APK_STUB_ADDED" | tr '\n' ' '; }
_starts() { grep -c '^start$' "$GATYGO_INIT_LOG"; }
_clean() {
    ls -d "$GATYGO_RUN/update.lock" "$GATYGO_RUN/upgrade.lock" "$GATYGO_CORE_DIR.prev" /tmp/gatygo-upgrade.* 2>/dev/null | wc -l | tr -d ' '
}

_r=$(_setup; _run; echo "$(_added new)/ $(_added old)/ $(_starts) $(cat "$GATYGO_CORE_DIR/xray") $(cat "$GATYGO_STATE/xray.json") $(_clean)")
assert_eq '0 "ok" "" false "skip" "ok"
new/gatygo.apk new/luci-app-gatygo.apk / / 1 old {"v":"new"} 0' "$_r" "success, the same core: new packages once, one start, nothing left over"

_r=$(_setup; export FAKE_CORE=installed; _run; echo "$(cat "$GATYGO_CORE_DIR/xray") $(cat "$GATYGO_CORE_DIR/pin") $(_clean)")
assert_eq '0 "ok" "" false "ok" "ok"
new newpin 0' "$_r" "success, a new core: the old one is gone"

assert_eq '0 "ok" "" false "warn" "ok"' "$(_setup; export FAKE_CORE=kept; _run)" "the new core was not downloaded: success with a warning"

_r=$(_setup; export FAKE_CORE=none; _run; echo "$(_added old)/ $(cat "$GATYGO_STATE/xray.json") $(cat "$GATYGO_CORE_DIR/xray") $(_starts) $(_clean)")
assert_eq '1 "failed" "core_failed" true "fail" "todo"
old/gatygo.apk old/luci-app-gatygo.apk / {"v":"old"} old 1 0' "$_r" "no core: rolled back and started again"

_r=$(_setup; export APK_STUB_ADD_FAIL=/new/; _run; echo "$(_j .steps.install) $(_added old)/ $(_clean)")
assert_eq '1 "failed" "install_failed" true "todo" "todo"
"fail" old/gatygo.apk old/luci-app-gatygo.apk / 0' "$_r" "apk refused: rolled back"

_r=$(_setup; export FAKE_CORE=installed GATYGO_CLI_APPLY_RC=1; _run
    echo "$(cat "$GATYGO_CORE_DIR/xray") $(cat "$GATYGO_CORE_DIR/pin") $(cat "$GATYGO_STATE/xray.json") $(_clean)")
assert_eq '1 "failed" "config_failed" true "ok" "fail"
old oldpin {"v":"old"} 0' "$_r" "the config does not build: the old core, pin and config are back"

_r=$(_setup; export GATYGO_CLI_APPLY_RC=2; _run)
assert_eq '1 "failed" "not_started" true "skip" "fail"' "$_r" "the rebuild waited in vain for the update lock"

_r=$(_setup; export PID_FILE="$GATYGO_RUN/pid"; _run; echo "$(cat "$GATYGO_STATE/xray.json") $(_clean)")
assert_eq '1 "failed" "not_started" true "skip" "fail"
{"v":"old"} 0' "$_r" "xray does not stay up: rolled back, the old config is back"

_r=$(_setup; export RUNNING=0 GATYGO_CLI_VERSION=20261105.1200; _run; _starts)
assert_eq '0 "ok" "" false "skip" "ok"
0' "$_r" "a VPN stopped by hand stays stopped"
_r=$(_setup; export RUNNING=0; _run)
assert_eq '0 "ok" "" false "skip" "ok"' "$_r" "the version is asked of the installed library, not of the executor's copy"
_r=$(_setup; export RUNNING=0 GATYGO_CLI_VERSION=20261027.1753; _run; _starts)
assert_eq '1 "failed" "not_started" true "skip" "fail"
0' "$_r" "stopped, and the new version does not answer: rolled back, still stopped"

_r=$(_setup; export FAKE_CORE=none APK_STUB_ADD_FAIL=/; _run)
assert_eq '1 "failed" "rollback_failed" false "todo" "todo"' "$_r" "the rollback fails too"

_r=$(_setup; rm -f "$GATYGO_STATE"/*; export RUNNING=0; _run)
assert_eq '0 "ok" "" false "skip" "ok"' "$_r" "no subscription yet"
_r=$(_setup; rm -f "$GATYGO_STATE/subscription.json"; export RUNNING=0 GATYGO_CLI_APPLY_RC=1; _run)
assert_eq '0 "ok" "" false "skip" "ok"' "$_r" "a link whose subscription never came: nothing to rebuild, no rollback"

# an update that holds the lock longer than the rebuild waits: wait for it again, no rollback
_r=$(_setup; export GATYGO_CLI_APPLY_BUSY_ONCE="$GATYGO_RUN/busy-once"; _run)
assert_eq '0 "ok" "" false "skip" "ok"' "$_r" "the rebuild waits out a long update"
# a cron update that slips in after the failed rebuild: the rollback waits for it, then puts the old config back
_r=$(_setup; export GATYGO_CLI_APPLY_RACE=1; _run; sleep 3; cat "$GATYGO_STATE/xray.json")
assert_eq '1 "failed" "config_failed" true "skip" "fail"
{"v":"old"}' "$_r" "the rollback takes the update lock: a cron update cannot write over it"

# the shell it was started from goes away (ssh dropped): the upgrade goes on
_r=$(_setup; export APK_STUB_ADD_SLEEP=2
    ( gatygo_upgrade_run >/dev/null 2>&1 ) &
    _bg=$!
    for _ in $(seq 1 50); do [ "$(_j .steps.install 2>/dev/null)" = '"now"' ] && break; sleep 0.1; done
    kill -HUP "$_bg"; wait "$_bg"
    _j .state)
assert_eq '"ok"' "$_r" "a hangup does not stop the upgrade"

_r=$(_setup; sleep 30 & _s=$!; mkdir -p "$GATYGO_RUN/upgrade.lock"; echo "$_s" > "$GATYGO_RUN/upgrade.lock/pid"
    gatygo_upgrade_run >/dev/null 2>&1; echo "$? $(ls "$GATYGO_RUN" | tr '\n' ' ')$(grep -c . "$APK_STUB_LOG")"; kill "$_s")
assert_eq "0 upgrade.lock 0" "$_r" "another upgrade runs: nothing touched"

_r=$(_setup; sleep 30 & _s=$!; mkdir -p "$GATYGO_RUN/update.lock"; echo "$_s" > "$GATYGO_RUN/update.lock/pid"
    _run; [ "$(cat "$GATYGO_RUN/update.lock/pid")" = "$_s" ] && echo "its lock stays"; kill "$_s")
assert_eq '1 "failed" "busy" false "todo" "todo"
its lock stays' "$_r" "an update runs: busy, and the update keeps its lock"

# a periodic update while the packages install waits its turn (the update lock)
_r=$(_setup; echo '{"sub":"before"}' > "$GATYGO_STATE/subscription.json"; : > "$SYSLOG_STUB_FILE"
    export APK_STUB_ADD_SLEEP=3
    ( gatygo_upgrade_run >/dev/null 2>&1 ) &
    _bg=$!
    for _ in $(seq 1 50); do [ "$(_j .steps.install 2>/dev/null)" = '"now"' ] && break; sleep 0.1; done
    sh /src/gatygo/files/gatygo update >/dev/null 2>&1
    wait "$_bg"
    echo "$(grep -c 'update skipped: another update is running' "$SYSLOG_STUB_FILE") $(_j .state)"
    cat "$GATYGO_STATE/subscription.json")
assert_eq '1 "ok"
{"sub":"before"}' "$_r" "cron during the install waits, the subscription is not touched"

# --- CLI: the executor runs from a copy of the library and leaves nothing in /tmp
CLI=/src/gatygo/files/gatygo
uci set gatygo.main.release_api=http://127.0.0.1:1/releases
_r=$(_setup; sh "$CLI" upgrade run >/dev/null 2>&1; echo "$? $(_j .state) $(_j .code) $(ls -d /tmp/gatygo-upgrade.* 2>/dev/null | wc -l | tr -d ' ')"
    sh "$CLI" upgrade dismiss; echo "$? $(ls "$GATYGO_RUN" | tr '\n' ' ')")
assert_eq '1 "failed" "no_release" 0
0 ' "$_r" "cli: upgrade run fails cleanly, dismiss drops the progress file"
uci set gatygo.main.release_api=http://127.0.0.1:8793/releases
_r=$(_setup; sleep 30 & _s=$!; mkdir -p "$GATYGO_RUN/upgrade.lock"; echo "$_s" > "$GATYGO_RUN/upgrade.lock/pid"
    echo '{"state":"running"}' > "$GATYGO_RUN/upgrade.json"
    sh "$CLI" upgrade running; echo "running $?"
    sh "$CLI" upgrade dismiss; echo "$(_j .state)"
    kill "$_s"; wait "$_s" 2>/dev/null
    sh "$CLI" upgrade running; echo "running $?")
assert_eq 'running 0
"running"
running 1' "$_r" "cli: running while the executor lives; dismiss leaves a running upgrade alone"
assert_exit 1 "cli: unknown upgrade action" sh "$CLI" upgrade nonsense

kill "$_srv" 2>/dev/null
rm -rf "$tmp"
report
