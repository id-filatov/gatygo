#!/bin/sh
# gatygo forget: the subscription and everything it brought go, the settings return to the
# package defaults, the xray core and the device ID stay.
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
CLI=/src/gatygo/files/gatygo
export GATYGO_STATE="$tmp/state" GATYGO_RUN="$tmp/run" GATYGO_ASSETS="$tmp/assets" GATYGO_CORE_DIR="$tmp/core" \
       GATYGO_INIT=/src/tests/stubs/gatygo-init GATYGO_INIT_LOG="$tmp/init.log" \
       GATYGO_DEFAULTS=/src/gatygo/files/gatygo.config
HWID=0123456789abcdef0123456789abcdef

# what a connected router holds
_populate() {
    rm -rf "$GATYGO_STATE" "$GATYGO_RUN" "$GATYGO_ASSETS"
    mkdir -p "$GATYGO_STATE" "$GATYGO_RUN/ping.lock" "$GATYGO_ASSETS" "$GATYGO_CORE_DIR"
    for f in subscription.json xray.json headers.env last-update.env profile geo-urls.env geo-source.env check.secret dnsmasq.backup; do
        echo x > "$GATYGO_STATE/$f"
    done
    for f in check.json ping.json crash.env crash.log swap-result stopped boot-update-done; do echo x > "$GATYGO_RUN/$f"; done
    for f in geosite.dat geoip.dat other.dat; do echo x > "$GATYGO_ASSETS/$f"; done
    echo x > "$GATYGO_CORE_DIR/xray"
    : > "$UCI_STUB_FILE"
    uci set gatygo.main=gatygo
    uci set gatygo.main.enabled=1
    uci set gatygo.main.sub_url=https://panel.example.com/sub/SECRETTOKEN
    uci set gatygo.main.user_agent=custom/1.0
    uci set gatygo.main.profile="📍 Bravo"
    uci set gatygo.main.tproxy_port=23456
    uci set gatygo.main.hwid=$HWID
    : > "$GATYGO_INIT_LOG"; : > "$SYSLOG_STUB_FILE"
}
# the package defaults as `uci show gatygo.main.` prints them
_defaults() { sed -n "s/^[[:space:]]*option \([a-z0-9_]*\) '\(.*\)'\$/gatygo.main.\1=\2/p" "$GATYGO_DEFAULTS"; }

# --- a connected router
_populate
assert_exit 0 "forget succeeds" sh "$CLI" forget
assert_eq "stop disable" "$(tr '\n' ' ' < "$GATYGO_INIT_LOG" | sed 's/ $//')" "the service is stopped (dnsmasq, firewall, cron put back) and disabled"
assert_eq "" "$(ls -A "$GATYGO_STATE")" "nothing of the subscription left in the state dir"
assert_exit 0 "the state dir itself stays (sysupgrade keep list)" test -d "$GATYGO_STATE"
assert_eq "" "$(ls -A "$GATYGO_RUN")" "the run dir is empty, the update lock released too"
assert_eq "other.dat" "$(ls "$GATYGO_ASSETS")" "gatygo's geo files go, anything else stays"
assert_exit 0 "the xray core stays" test -s "$GATYGO_CORE_DIR/xray"
assert_eq "$(_defaults | sed "s/^gatygo.main.hwid=\$/gatygo.main.hwid=$HWID/" | sort)" "$(uci show gatygo.main. | sort)" \
    "the settings are the package defaults, the device ID kept"
assert_eq "1" "$(grep -c '\[info\] subscription removed$' "$SYSLOG_STUB_FILE")" "one log line says so"
assert_exit 1 "the link never reaches the log" grep -q SECRETTOKEN "$SYSLOG_STUB_FILE"

# --- an update is running: nothing is touched
_populate
mkdir -p "$GATYGO_RUN/update.lock"; sleep 30 & _upd=$!; echo "$_upd" > "$GATYGO_RUN/update.lock/pid"
assert_exit 2 "busy while an update runs" sh "$CLI" forget
assert_eq "an update is running; try again when it finishes" "$(sh "$CLI" forget 2>&1 >/dev/null)" "busy says why"
assert_eq "" "$(cat "$GATYGO_INIT_LOG")" "the service is left alone"
assert_exit 0 "the subscription stays" test -s "$GATYGO_STATE/subscription.json"
assert_eq "https://panel.example.com/sub/SECRETTOKEN" "$(uci get gatygo.main.sub_url)" "and the settings too"
assert_eq "$_upd" "$(cat "$GATYGO_RUN/update.lock/pid")" "the update keeps its lock"
kill "$_upd" 2>/dev/null; wait "$_upd" 2>/dev/null

# --- geo files gatygo did not download (no record of their source) are not its to delete
_populate; rm -f "$GATYGO_STATE/geo-source.env"
sh "$CLI" forget 2>/dev/null
assert_eq "geoip.dat geosite.dat other.dat" "$(ls "$GATYGO_ASSETS" | tr '\n' ' ' | sed 's/ $//')" "geo files of unknown origin stay"

# --- the VPN could not be stopped: nothing is erased under a running xray
_populate
assert_exit 1 "a failed stop fails" env GATYGO_INIT_STOP_RC=1 sh "$CLI" forget
assert_eq "the VPN could not be stopped" "$(GATYGO_INIT_STOP_RC=1 sh "$CLI" forget 2>&1 >/dev/null)" "and says so"
assert_exit 0 "the subscription stays" test -s "$GATYGO_STATE/subscription.json"
assert_exit 1 "the lock is released" test -d "$GATYGO_RUN/update.lock"
assert_exit 1 "not disabled" grep -q '^disable$' "$GATYGO_INIT_LOG"

# --- nothing to delete (never connected, or deleted already, e.g. from a second tab): exit 0
rm -rf "$GATYGO_STATE" "$GATYGO_RUN"; : > "$UCI_STUB_FILE"
assert_exit 0 "forget on a clean router" sh "$CLI" forget
assert_eq "0" "$(uci get gatygo.main.enabled)" "the defaults are written"
assert_exit 0 "and again" sh "$CLI" forget

rm -rf "$tmp"
report
