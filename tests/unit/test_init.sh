#!/bin/sh
# The init script's own decisions (procd, the firewall and dnsmasq are stand-ins): after a reboot
# the default geo files come again in the background, and the VPN waits for them only when its
# config names geo data.
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state" GATYGO_RUN="$tmp/run" GATYGO_ASSETS="$tmp/assets" GATYGO_CORE_DIR="$tmp/core" \
       GATYGO_XRAY="$tmp/core/xray" GATYGO_INIT=/src/tests/stubs/gatygo-init GATYGO_INIT_LOG="$tmp/init.log" \
       GATYGO_GEO_DEFAULT_BASE=http://127.0.0.1:8790/geo/default GATYGO_GEO_RETRY_DELAY=1 NSLOOKUP_STUB_FILE="$tmp/dns"
mkdir -p "$GATYGO_STATE" "$GATYGO_RUN" "$GATYGO_ASSETS" "$GATYGO_CORE_DIR" "$tmp/geo-src" "$tmp/geo-away"
printf '#!/bin/sh\n' > "$GATYGO_XRAY"; chmod +x "$GATYGO_XRAY"
cp "$FIXTURES/geo/"*.dat "$tmp/geo-away/"
echo "localhost 127.0.0.1" > "$tmp/dns"

python3 /src/tests/mock/sub_server.py 8790 "$FIXTURES/subscription.json" "$tmp/geo-src" http://127.0.0.1:8790 &
_mock=$!
for _ in $(seq 1 50); do curl -fs -o /dev/null http://127.0.0.1:8790/log && break; sleep 0.1; done

# the init script with this tree's libraries and a stand-in for the CLI; the real _gatygo_env,
# then stand-ins for what reaches the firewall, dnsmasq and cron
sed -e "s#^GATYGO_LIB=.*#GATYGO_LIB=$GATYGO_LIB#" -e "s#/usr/bin/gatygo#$tmp/cli#g" \
    -e 's/^_gatygo_env() {/_gatygo_env_real() {/' /src/gatygo/files/gatygo.init > "$tmp/init.sh"
printf '#!/bin/sh\necho "$*" >> %s\n' "$tmp/cli.log" > "$tmp/cli"; chmod +x "$tmp/cli"
procd_open_instance() { echo "open $1" >> "$tmp/procd.log"; }
procd_set_param() { :; }
procd_close_instance() { :; }
procd_open_service() { :; }
procd_close_service() { :; }
. "$tmp/init.sh"
_gatygo_env() {
    _gatygo_env_real
    gatygo_fw_apply() { echo fw_apply >> "$tmp/calls"; }
    gatygo_fw_remove() { echo fw_remove >> "$tmp/calls"; }
    gatygo_dns_restore() { echo dns_restore >> "$tmp/calls"; }
    gatygo_dns_apply() { echo dns_apply >> "$tmp/calls"; }
    gatygo_cron_sync() { :; }
    gatygo_cron_remove() { :; }
    gatygo_relay_note() { :; }
}
CLI=/src/gatygo/files/gatygo
_calls() { tr '\n' ' ' < "$tmp/calls" 2>/dev/null | sed 's/ $//'; }
_wait() { _gatygo_env_get "$GATYGO_RUN/geo-wait" "$1"; }
_worker() { cat "$GATYGO_RUN/geo-retry" 2>/dev/null; }
# _gone PID — wait (up to 30 s) until PID is gone; busybox `kill -0 ""` means the whole process group
_gone() { [ -n "$1" ] || return 0; _i=0; while kill -0 "$1" 2>/dev/null && [ "$_i" -lt 30 ]; do _i=$((_i + 1)); sleep 1; done; }
_reset() { : > "$tmp/calls"; : > "$tmp/procd.log"; : > "$GATYGO_INIT_LOG"; : > "$tmp/cli.log"; rm -rf "$GATYGO_RUN/geo" "$GATYGO_RUN/stopped"; }

# a router that ran on the default geo files before the reboot: the config names geo data, the
# links on the flash lead into the empty RAM
: > "$UCI_STUB_FILE"; uci set gatygo.main=gatygo; uci set gatygo.main.enabled=1
printf '{"routing":{"rules":[{"domain":["geosite:category-ru"],"outboundTag":"direct"}]}}' > "$tmp/geo.json"
printf '{"routing":{"rules":[{"domain":["domain:example.com"],"outboundTag":"direct"}]}}' > "$tmp/nogeo.json"
cp "$tmp/geo.json" "$GATYGO_STATE/xray.json"
printf "GATYGO_GEOSITE_URL='%s'\nGATYGO_GEOIP_URL='%s'\nGATYGO_GEO_DEFAULT='1'\n" \
    "$GATYGO_GEO_DEFAULT_BASE/geosite.dat" "$GATYGO_GEO_DEFAULT_BASE/geoip.dat" > "$GATYGO_STATE/geo-source.env"
for n in geosite.dat geoip.dat; do ln -s "$GATYGO_RUN/geo/$n" "$GATYGO_ASSETS/$n"; done

# --- the VPN waits for them; on_crash=block (the default) keeps the home network closed meanwhile
_reset
start_service; assert_eq "1" "$?" "the config names geo data, the files are not there: no start yet"
assert_eq "" "$(cat "$tmp/procd.log")" "no xray instance while the files are missing"
assert_eq "dns_restore fw_apply" "$(_calls)" "the router's DNS for the download, the home network closed"
# the download in the background may have failed already: the first state either way
case $(_wait GATYGO_GEO_WAIT) in downloading | failed) _t_ok ;; *) _t_bad "the page is told the VPN waits: $(_wait GATYGO_GEO_WAIT)" ;; esac
assert_eq "1" "$(_wait GATYGO_GEO_BLOCK)" "and that the home network is closed"
assert_eq "" "$(cat "$tmp/cli.log")" "the subscription is not downloaded"
assert_exit 0 "the download goes on in the background" test -n "$(_worker)" -a -d "/proc/$(_worker)"
_t0=$(date +%s); service_started; _t1=$(date +%s)
assert_exit 0 "service_started does not wait for an xray that is not coming" test $((_t1 - _t0)) -lt 3
assert_eq "dns_restore fw_apply" "$(_calls)" "and does nothing else"
sleep 2
assert_eq "failed true true" "$(sh "$CLI" status | jq -r '.geo.wait | "\(.state) \(.block) \(.next > 0)"')" "status: the VPN waits for the geo files, the home network closed, the next try"
# Start pressed meanwhile: the same wait, no second download
_p=$(_worker); start_service
assert_eq "$_p" "$(_worker)" "Start while it waits: no second download"
# GitHub answers: the files come, and the service is started
cp "$tmp/geo-away/"*.dat "$tmp/geo-src/"
_gone "$_p"
assert_eq "start" "$(cat "$GATYGO_INIT_LOG")" "the files are there: the service is started"
: > "$tmp/procd.log"
start_service; assert_eq "0" "$?" "the start after it"
assert_eq "open xray open watch" "$(tr '\n' ' ' < "$tmp/procd.log" | sed 's/ $//')" "runs xray"
assert_eq "null" "$(sh "$CLI" status | jq -c .geo.wait)" "status: nothing waits any more"

# --- on_crash=direct: the home network uses the regular internet meanwhile
_reset; rm -f "$tmp/geo-src/"*.dat; uci set gatygo.main.on_crash=direct
start_service
assert_eq "dns_restore" "$(_calls)" "direct: the home network is not closed"
assert_eq "0" "$(_wait GATYGO_GEO_BLOCK)" "the page is told it is not closed"
# Stop meanwhile: the wait is over, the page is told at once
stop_service
assert_exit 1 "stop: the download no longer starts the service" test -e "$GATYGO_RUN/geo-start"
assert_exit 1 "stop: the page is not told the VPN waits any more" test -e "$GATYGO_RUN/geo-wait"
assert_exit 0 "stop: stopped by hand" test -e "$GATYGO_RUN/stopped"
_gone "$(_worker)"
assert_eq "" "$(cat "$GATYGO_INIT_LOG")" "stop: no start after it"
uci delete gatygo.main.on_crash

# --- the selected profile names no geo data: the VPN starts at once, the files follow for the others
_reset; cp "$tmp/nogeo.json" "$GATYGO_STATE/xray.json"; cp "$tmp/geo-away/"*.dat "$tmp/geo-src/"
start_service; assert_eq "0" "$?" "no geo data in the config: the start goes on"
assert_eq "open xray open watch" "$(tr '\n' ' ' < "$tmp/procd.log" | sed 's/ $//')" "xray runs at once"
assert_exit 1 "nothing waits: the page is not told" test -e "$GATYGO_RUN/geo-wait"
_gone "$(_worker)"
assert_exit 0 "the files follow in the background" test -s "$GATYGO_RUN/geo/geoip.dat"
assert_eq "" "$(cat "$GATYGO_INIT_LOG")" "and no start after them"

# --- the boot-time refresh in the background lets go of procd's lock (rc.common, fd 1000):
#     kept, a Stop would wait for it
_reset; rm -f "$GATYGO_RUN/boot-update-done"; cp "$tmp/geo.json" "$GATYGO_STATE/xray.json"
exec 1000>"$tmp/procd.lock"
UBUS_STUB_RUNNING=1 service_started
exec 1000>&-
_holders=0
for _f in /proc/[0-9]*/fd/1000; do [ "$(readlink "$_f" 2>/dev/null)" = "$tmp/procd.lock" ] && _holders=$((_holders + 1)); done
assert_eq "0" "$_holders" "the boot-time refresh does not hold the init script's lock"
pkill -f "^sleep 30$" 2>/dev/null

kill $_mock 2>/dev/null; rm -rf "$tmp"
report
