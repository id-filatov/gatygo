#!/bin/sh
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_SYSROOT="$FIXTURES/sysroot" GATYGO_STATE="$tmp/state" GATYGO_ASSETS="$tmp/assets" \
       GATYGO_RUN="$tmp/run" GATYGO_INIT=/src/tests/stubs/gatygo-init \
       GATYGO_INIT_LOG="$tmp/init.log"
mkdir -p "$GATYGO_ASSETS" "$tmp/geo-src"
cp "$FIXTURES/geo/"*.dat "$tmp/geo-src/"
: > "$UCI_STUB_FILE"; : > "$GATYGO_INIT_LOG"
. "$GATYGO_LIB/config.sh"
. "$GATYGO_LIB/update.sh"

python3 /src/tests/mock/sub_server.py 8789 "$FIXTURES/subscription.json" "$tmp/geo-src" http://127.0.0.1:8789 &
_mock=$!
for _ in $(seq 1 50); do curl -fs -o /dev/null http://127.0.0.1:8789/log && break; sleep 0.1; done
_geo_requests() { curl -fs http://127.0.0.1:8789/log | jq '[.[] | select(.path | startswith("/geo/"))] | length'; }
_last() { ( . "$GATYGO_STATE/last-update.env"; eval "printf '%s' \"\$$1\"" ); }
# stderr goes to its own file so the leak check below covers both it and the system log

# --- no URL configured
gatygo_update 2>>"$tmp/stderr.log"; assert_eq "1" "$?" "no sub_url -> error"
assert_eq "error" "$(_last RESULT)" "result recorded"
assert_exit 0 "result lives in the state dir, not in tmpfs (the UI shows it after a reboot)" test -f "$GATYGO_STATE/last-update.env"
assert_exit 1 "nothing in the run dir" test -f "$GATYGO_RUN/last-update.env"

# --- first update from an empty state
uci set gatygo.main.sub_url=http://127.0.0.1:8789/sub
gatygo_update 2>>"$tmp/stderr.log"; assert_eq "0" "$?" "first update succeeds"
assert_eq "ok" "$(_last RESULT)" "RESULT=ok"
assert_eq "🌐 Auto" "$(_last PROFILE)" "first balancer profile used when profile is empty"
assert_eq "1" "$(_last RESTARTED)" "first apply asks for a reload"
assert_eq "1" "$(grep -c ' gatygo\[[0-9]*\]: .*\[info\] subscription updated$' "$SYSLOG_STUB_FILE")" "result message goes to the system log (cron and rpcd show nothing else)"
assert_eq "running start" "$(tr '\n' ' ' < "$GATYGO_INIT_LOG" | sed 's/ $//')" "init asked: running? then start (procd re-submits the instance)"
assert_exit 0 "xray.json installed" test -s "$GATYGO_STATE/xray.json"
assert_eq "-rw-------" "$(ls -l "$GATYGO_STATE/xray.json" | cut -c1-10)" "xray.json is 0600"
assert_eq "-rw-------" "$(ls -l "$GATYGO_STATE/subscription.json" | cut -c1-10)" "subscription.json is 0600"
assert_exit 0 "headers.env saved" test -s "$GATYGO_STATE/headers.env"
assert_exit 0 "geo installed" test -s "$GATYGO_ASSETS/geoip.dat"
assert_eq '["tproxy","dns-in","api"]' "$(jq -c '[.inbounds[].tag]' "$GATYGO_STATE/xray.json")" "installed config is transformed"
assert_eq "2" "$(_geo_requests)" "both geo files downloaded once"
_sha1=$(sha256sum < "$GATYGO_STATE/xray.json")

# --- second update, nothing changed: no reload, no geo traffic
: > "$GATYGO_INIT_LOG"
gatygo_update 2>>"$tmp/stderr.log"; assert_eq "0" "$?" "unchanged update succeeds"
assert_eq "0" "$(_last RESTARTED)" "unchanged -> no restart"
assert_eq "" "$(cat "$GATYGO_INIT_LOG")" "init not called when nothing changed"
assert_eq "$_sha1" "$(sha256sum < "$GATYGO_STATE/xray.json")" "xray.json untouched"
assert_eq "2" "$(_geo_requests)" "geo not re-downloaded while fresh and subscription unchanged"

# --- profile switch
uci set gatygo.main.profile="📍 Bravo"
: > "$GATYGO_INIT_LOG"
gatygo_update 2>>"$tmp/stderr.log"
assert_eq "📍 Bravo" "$(_last PROFILE)" "profile from UCI"
assert_eq "1" "$(_last RESTARTED)" "profile change restarts"
assert_eq "11" "$(jq '.outbounds | length' "$GATYGO_STATE/xray.json")" "Bravo: 10 outbounds + dns-out"

# --- profile missing from the subscription -> warning + fallback
uci set gatygo.main.profile="📍 Missing"
gatygo_update 2>>"$tmp/stderr.log"; assert_eq "0" "$?" "fallback is not an error"
assert_eq "warning" "$(_last RESULT)" "RESULT=warning"
assert_eq "🌐 Auto" "$(_last PROFILE)" "fell back to the first balancer profile"
uci set gatygo.main.profile="📍 Bravo"; gatygo_update 2>>"$tmp/stderr.log"
_sha_de=$(sha256sum < "$GATYGO_STATE/xray.json")

# --- panel errors keep the current config
uci set gatygo.main.sub_url=http://127.0.0.1:8789/sub-maxdev
gatygo_update 2>>"$tmp/stderr.log"; assert_eq "1" "$?" "device limit -> error"
case $(_last MESSAGE) in *"device limit"*) _t_ok ;; *) _t_bad "message mentions the device limit: $(_last MESSAGE)" ;; esac
assert_eq "$_sha_de" "$(sha256sum < "$GATYGO_STATE/xray.json")" "config untouched on device limit"
uci set gatygo.main.sub_url=http://127.0.0.1:8789/sub-broken
gatygo_update 2>>"$tmp/stderr.log"; assert_eq "1" "$?" "HTTP 500 -> error"
assert_eq "$_sha_de" "$(sha256sum < "$GATYGO_STATE/xray.json")" "config untouched on HTTP error"
uci set gatygo.main.sub_url=http://127.0.0.1:1/sub
gatygo_update 2>>"$tmp/stderr.log"; assert_eq "1" "$?" "unreachable -> error"
uci set gatygo.main.sub_url=http://127.0.0.1:8789/sub
uci set gatygo.main.user_agent="curl/8.0"
gatygo_update 2>>"$tmp/stderr.log"; assert_eq "1" "$?" "wrong format (unknown UA) -> error"
case $(_last MESSAGE) in *User-Agent*) _t_ok ;; *) _t_bad "message hints at the User-Agent: $(_last MESSAGE)" ;; esac
uci delete gatygo.main.user_agent
assert_eq "0" "$(cat "$SYSLOG_STUB_FILE" "$tmp/stderr.log" | grep -c '127.0.0.1')" "system log and stderr never contain the subscription host"

# --- geo refresh when due: identical content -> no restart
touch -d '2026-01-01 00:00:00' "$GATYGO_ASSETS/geosite.dat" "$GATYGO_ASSETS/geoip.dat"
_before=$(_geo_requests)
gatygo_update 2>>"$tmp/stderr.log"
assert_eq "$((_before + 2))" "$(_geo_requests)" "geo re-checked when older than 24h"
assert_eq "0" "$(_last RESTARTED)" "same geo content -> no restart"

# --- service not running: no reload call
: > "$GATYGO_INIT_LOG"; uci set gatygo.main.profile="📍 Golf"
GATYGO_INIT_RUNNING_RC=1 gatygo_update 2>>"$tmp/stderr.log"
assert_eq "running" "$(cat "$GATYGO_INIT_LOG")" "reload skipped when the service is not running"
assert_eq "1" "$(_last RESTARTED)" "but the change is recorded"

# --- no geo URLs in the subscription, no geo files yet: nothing downloaded, the error says why
GATYGO_STATE="$tmp/state-norouting" GATYGO_ASSETS="$tmp/assets-norouting"
mkdir -p "$GATYGO_ASSETS"; uci set gatygo.main.sub_url=http://127.0.0.1:8789/sub-norouting; uci set gatygo.main.profile=""
_before=$(_geo_requests)
gatygo_update 2>>"$tmp/stderr.log"; assert_eq "1" "$?" "templates with geo rules and no geo files -> error"
assert_eq "$_before" "$(_geo_requests)" "no geo download without URLs"
case $(_last MESSAGE) in *"no geo file URLs"*) _t_ok ;; *) _t_bad "error names the missing geo URLs: $(_last MESSAGE)" ;; esac
assert_exit 1 "no config installed" test -e "$GATYGO_STATE/xray.json"

# --- geo files of unknown origin with a fresh mtime (feed package, another panel, a wiped state dir):
#     replaced on the first update, their source recorded, later fetches conditional
GATYGO_STATE="$tmp/state-foreign" GATYGO_ASSETS="$tmp/assets-foreign"; mkdir -p "$GATYGO_ASSETS"
printf 'not a geosite\n' > "$GATYGO_ASSETS/geosite.dat"; printf 'not a geoip\n' > "$GATYGO_ASSETS/geoip.dat"
uci set gatygo.main.sub_url=http://127.0.0.1:8789/sub; uci set gatygo.main.profile=""
gatygo_update 2>>"$tmp/stderr.log"; assert_eq "0" "$?" "foreign geo files do not block the first update"
assert_eq "$(sha256sum < "$FIXTURES/geo/geosite.dat")" "$(sha256sum < "$GATYGO_ASSETS/geosite.dat")" "geosite replaced by the subscription's file"
assert_eq "http://127.0.0.1:8789/geo/geoip.dat" "$(_gatygo_env_get "$GATYGO_STATE/geo-source.env" GATYGO_GEOIP_URL)" "source of the installed files recorded"
touch -d '2026-01-01 00:00:00' "$GATYGO_ASSETS/geosite.dat" "$GATYGO_ASSETS/geoip.dat"
_before=$(_geo_requests)
gatygo_update 2>>"$tmp/stderr.log"
assert_eq "$((_before + 2))" "$(_geo_requests)" "due again -> re-checked"
assert_eq "true" "$(curl -fs http://127.0.0.1:8789/log | jq '[.[] | select(.path == "/geo/geosite.dat")][-1].headers | has("if-modified-since")')" "recorded source -> conditional GET"
assert_eq "0" "$(_last RESTARTED)" "304 -> nothing changed"

# --- send_hwid=0: no hwid generated, no x-hwid header, update still succeeds
GATYGO_STATE="$tmp/state-nohwid" GATYGO_ASSETS="$tmp/assets-nohwid"; mkdir -p "$GATYGO_ASSETS"
uci delete gatygo.main.hwid; uci set gatygo.main.send_hwid=0; uci set gatygo.main.sub_url=http://127.0.0.1:8789/sub-nohwid; uci set gatygo.main.profile=""
gatygo_update 2>>"$tmp/stderr.log"; assert_eq "0" "$?" "update succeeds without a hwid"
assert_eq "" "$(uci -q get gatygo.main.hwid)" "no hwid generated when send_hwid=0"
assert_eq "false" "$(curl -fs http://127.0.0.1:8789/log | jq '[.[] | select(.path == "/sub-nohwid")][-1].headers | has("x-hwid")')" "request carried no x-hwid"
uci set gatygo.main.send_hwid=1

kill $_mock 2>/dev/null; rm -rf "$tmp"
report
