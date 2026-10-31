#!/bin/sh
# The router learns about a newer gatygo release by itself: GitHub's releases/latest, at most
# once a day, kept in the state dir; `gatygo status` hands it to the page. GitHub here is a
# local http.server with release JSON files.
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state" GATYGO_RUN="$tmp/run"
mkdir -p "$GATYGO_STATE" "$GATYGO_RUN" "$tmp/www/releases/tags"
: > "$UCI_STUB_FILE"; : > "$SYSLOG_STUB_FILE"
# the installed version is the one in the library's version file
cp -a "$GATYGO_LIB" "$tmp/lib"
echo 20261027.1753 > "$tmp/lib/version"
export GATYGO_LIB="$tmp/lib"
. "$GATYGO_LIB/upgrade.sh"
gatygo_load_config

A64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# _release FILE TAG [luci] — a GitHub release: the luci asset first (when asked), then gatygo
_release() {
    jq -n --arg tag "$2" --arg luci "${3:-}" --arg digest "sha256:$A64" '
        ($tag | ltrimstr("v")) as $v
        | {tag_name: $tag, draft: false, prerelease: false,
           assets: ((if $luci == "" then [] else
                [{name: "luci-app-gatygo-\($v)-r1.apk",
                  browser_download_url: "http://127.0.0.1:8793/assets/luci-app-gatygo-\($v)-r1.apk"}] end)
              + [{name: "gatygo-\($v)-r1.apk", digest: $digest,
                  browser_download_url: "http://127.0.0.1:8793/assets/gatygo-\($v)-r1.apk"}])}' > "$1"
}
_release "$tmp/rel.json" v20261105.1200 luci
_release "$tmp/rel-badtag.json" 20261105.1200 luci
_release "$tmp/rel-noluci.json" v20261105.1200
cp "$tmp/rel.json" "$tmp/www/releases/latest"

python3 -m http.server 8793 --bind 127.0.0.1 --directory "$tmp/www" >/dev/null 2>&1 &
_srv=$!
for _ in $(seq 1 50); do curl -fs -o /dev/null http://127.0.0.1:8793/releases/latest && break; sleep 0.1; done
uci set gatygo.main.release_api=http://127.0.0.1:8793/releases

# --- version order: date first, then time; a dev build and garbage are never compared
assert_exit 0 "newer by time" gatygo_upgrade_newer 20261105.1200 20261105.1159
assert_exit 0 "newer by date" gatygo_upgrade_newer 20261106.0000 20261105.2359
assert_exit 1 "same" gatygo_upgrade_newer 20261105.1200 20261105.1200
assert_exit 1 "older" gatygo_upgrade_newer 20261104.1200 20261105.1200
assert_exit 1 "dev build is never older" gatygo_upgrade_newer 20261105.1200 dev
assert_exit 1 "garbage" gatygo_upgrade_newer 2026.1 20261105.1200

# --- where releases come from
assert_eq "http://127.0.0.1:8793/releases" "$(gatygo_upgrade_api)" "release_api from UCI"
uci set gatygo.main.release_api=http://127.0.0.1:8793/releases/
assert_eq "http://127.0.0.1:8793/releases" "$(gatygo_upgrade_api)" "release_api without the trailing slash"
uci set gatygo.main.release_api=http://127.0.0.1:8793/releases
assert_eq "https://raw.githubusercontent.com/id-filatov/gatygo" "$(gatygo_upgrade_raw)" "raw: GitHub by default"
uci delete gatygo.main.release_api
assert_eq "https://api.github.com/repos/id-filatov/gatygo/releases" "$(gatygo_upgrade_api)" "api: GitHub by default"
uci set gatygo.main.release_api=http://127.0.0.1:8793/releases

# --- a GitHub release, boiled down to what the upgrade needs
assert_eq "{\"version\":\"20261105.1200\",\"gatygo\":{\"url\":\"http://127.0.0.1:8793/assets/gatygo-20261105.1200-r1.apk\",\"sha256\":\"$A64\"},\"luci\":{\"url\":\"http://127.0.0.1:8793/assets/luci-app-gatygo-20261105.1200-r1.apk\",\"sha256\":\"\"}}" \
  "$(gatygo_upgrade_release "$tmp/rel.json")" "parsed"
assert_exit 1 "tag not vNNNNNNNN.NNNN" gatygo_upgrade_release "$tmp/rel-badtag.json"
assert_eq "" "$(gatygo_upgrade_release "$tmp/rel-badtag.json")" "nothing printed for a bad tag"
assert_exit 1 "no luci asset" gatygo_upgrade_release "$tmp/rel-noluci.json"
assert_exit 1 "not JSON" gatygo_upgrade_release /src/install.sh

# --- once a day
assert_exit 0 "due: never checked" gatygo_upgrade_due
gatygo_upgrade_check
assert_eq "0" "$?" "check exit 0"
assert_eq "20261105.1200" "$(jq -r .version "$GATYGO_STATE/upgrade-latest.json")" "check stored the version"
assert_eq "-rw-------" "$(ls -l "$GATYGO_STATE/upgrade-latest.json" | cut -c1-10)" "stored 0600"
_checked=$(jq .checked "$GATYGO_STATE/upgrade-latest.json")
assert_exit 0 "checked is the time of the check" test "$(($(date +%s) - _checked))" -lt 10
assert_exit 1 "not due right after" gatygo_upgrade_due
touch -t "$(date -d "@$(($(date +%s) - 86401))" +%Y%m%d%H%M.%S)" "$GATYGO_STATE/upgrade-latest.json"
assert_exit 0 "due after a day" gatygo_upgrade_due

# --- someone else is checking: quiet exit 0, nothing written
gatygo_lock upgrade-check
assert_exit 0 "check while another one runs" gatygo_upgrade_check
assert_eq "$_checked" "$(jq .checked "$GATYGO_STATE/upgrade-latest.json")" "and leaves the stored answer alone"
gatygo_unlock upgrade-check

# --- server down: the previous version is kept, checked renewed, exit 1, one warn line
: > "$SYSLOG_STUB_FILE"
uci set gatygo.main.release_api=http://127.0.0.1:1/releases
echo '{"checked":1,"version":"20261105.1200"}' > "$GATYGO_STATE/upgrade-latest.json"
assert_exit 1 "check with GitHub down" gatygo_upgrade_check
assert_eq "20261105.1200" "$(jq -r .version "$GATYGO_STATE/upgrade-latest.json")" "previous version kept"
assert_exit 0 "checked renewed" test "$(jq .checked "$GATYGO_STATE/upgrade-latest.json")" -gt 1
assert_eq "1" "$(grep -c 'upgrade: no answer about the latest release' "$SYSLOG_STUB_FILE")" "one warn line in the log"
rm -f "$GATYGO_STATE/upgrade-latest.json"
gatygo_upgrade_check 2>/dev/null
assert_eq "null" "$(jq .version "$GATYGO_STATE/upgrade-latest.json")" "never answered -> null"
uci set gatygo.main.release_api=http://127.0.0.1:8793/releases

# --- what the page gets
assert_eq '{"latest":null,"available":false,"run":null}' "$(gatygo_upgrade_status_json)" "nothing known yet"
gatygo_upgrade_check
assert_eq "true" "$(gatygo_upgrade_status_json | jq .available)" "newer than installed 20261027.1753"
assert_eq "20261105.1200" "$(gatygo_upgrade_status_json | jq -r .latest)" "latest"
assert_eq "null" "$(gatygo_upgrade_status_json | jq .run)" "no run yet"
echo '{"state":"running","from":"20261027.1753","to":"20261105.1200"}' > "$GATYGO_RUN/upgrade.json"
assert_eq "running" "$(gatygo_upgrade_status_json | jq -r .run.state)" "run: the progress file"
rm -f "$GATYGO_RUN/upgrade.json"
echo 20261105.1200 > "$GATYGO_LIB/version"; gatygo_load_config
assert_eq "false" "$(gatygo_upgrade_status_json | jq .available)" "not newer than itself"
echo 20261027.1753 > "$GATYGO_LIB/version"; gatygo_load_config

# --- the same list of conflicting packages as install.sh
assert_eq '["luci-app-passwall","luci-app-passwall2","luci-app-openclash","luci-app-homeproxy"]' \
  "$(sed -n 's/^CONFLICTS="\(.*\)"$/\1/p' /src/install.sh | jq -Rc 'split(" ")')" "install.sh lists the same conflicts"
assert_eq "$(sed -n 's/^CONFLICTS="\(.*\)"$/\1/p' /src/install.sh)" "$GATYGO_UPGRADE_CONFLICTS" "upgrade.sh lists them too"

# --- CLI
CLI=/src/gatygo/files/gatygo
assert_eq "true 20261105.1200" "$(sh "$CLI" status | jq -r '"\(.upgrade.available) \(.upgrade.latest)"')" "cli: status has the upgrade"
assert_exit 1 "cli: upgrade due right after a check" sh "$CLI" upgrade due
rm -f "$GATYGO_STATE/upgrade-latest.json"
assert_exit 0 "cli: upgrade due when never checked" sh "$CLI" upgrade due
assert_exit 0 "cli: upgrade check" sh "$CLI" upgrade check
assert_eq "20261105.1200" "$(jq -r .version "$GATYGO_STATE/upgrade-latest.json")" "cli: check stored the version"
assert_exit 1 "cli: unknown upgrade action" sh "$CLI" upgrade nonsense

kill "$_srv" 2>/dev/null
rm -rf "$tmp"
report
