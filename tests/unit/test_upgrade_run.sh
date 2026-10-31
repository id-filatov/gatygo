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

# --- nothing was installed by any of the above
assert_exit 0 "the simulations are in the apk log" grep -q -- '^add --simulate' "$APK_STUB_LOG"
assert_eq "0" "$(grep '^add' "$APK_STUB_LOG" | grep -vc -- '--simulate')" "apk add only ever simulated"

kill "$_srv" 2>/dev/null
rm -rf "$tmp"
report
