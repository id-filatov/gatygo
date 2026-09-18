#!/bin/sh
# xray quit and procd no longer restarts it: what gatygo notes about it (when, how, the last
# lines worth reading) and what it does to the home network, by the on_crash setting.
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state" GATYGO_RUN="$tmp/run" GATYGO_DNSMASQ_INIT=/src/tests/stubs/dnsmasq-init \
       GATYGO_DNSMASQ_LOG="$tmp/dnsmasq.log"
mkdir -p "$GATYGO_STATE" "$GATYGO_RUN"; : > "$UCI_STUB_FILE"; : > "$GATYGO_DNSMASQ_LOG"
. "$GATYGO_LIB/crash.sh"
# the firewall commands are not in the test image: note what would have been run
nft() { echo "nft $*" >> "$tmp/fw.log"; }
ip() { echo "ip $*" >> "$tmp/fw.log"; }
: > "$tmp/fw.log"

# --- which of procd's notifications means it
assert_exit 0 "procd gave up on gatygo's xray" gatygo_watch_line '{ "instance.fail": {"service":"gatygo","instance":"xray"} }'
assert_exit 1 "a respawn is not the end" gatygo_watch_line '{ "instance.respawn": {"service":"gatygo","instance":"xray"} }'
assert_exit 1 "another service" gatygo_watch_line '{ "instance.fail": {"service":"dnsmasq","instance":"dnsmasq"} }'
assert_exit 1 "gatygo's other instance" gatygo_watch_line '{ "instance.fail": {"service":"gatygo","instance":"watch"} }'

# --- the default is to block
gatygo_load_config
assert_eq "block" "$GATYGO_ON_CRASH" "on_crash defaults to block"
uci set gatygo.main.on_crash=whatever; gatygo_load_config
assert_eq "block" "$GATYGO_ON_CRASH" "anything but direct is block"
uci delete gatygo.main.on_crash

# --- the lines worth showing: xray's own from the last minutes and the kernel killing it; not the
#     balancer's probes, not the banner of every restart, not an error from an hour ago
_now=$(date +%s)
_l() { printf 'Fri Sep 18 21:00:00 2026 [%s.000] %s\n' "$((_now - $1))" "$2"; }
{
    _l 3600 'daemon.err xray[900]: 2026/09/18 20:00:00 [Error] app/dns: an hour ago, nothing to do with it'
    _l 60 'daemon.info gatygo: 2026-09-18T21:00:01 [info] subscription updated'
    _l 50 'daemon.err xray[900]: 2026/09/18 21:00:02 [Warning] app/observatory/burst: error ping https://probe.example.com/generate_204 with proxy-7: timeout'
    _l 40 'daemon.err xray[900]: 2026/09/18 21:00:03 [Error] transport/internet: first'
    _l 35 'kern.err kernel: [ 4242.100000] Out of memory: Killed process 777 (uhttpd) total-vm:9000kB'
    _l 30 'daemon.err xray[900]: fatal error: runtime: out of memory'
    _l 30 'kern.err kernel: [ 4242.500000] Out of memory: Killed process 900 (xray) total-vm:1300000kB, anon-rss:61000kB'
    _l 25 'daemon.err xray[901]: Xray 26.9.9 (Xray, Penetrates Everything.) 52a412d (go1.27.1 linux/arm64)'
    _l 25 'daemon.err xray[901]: A unified platform for anti-censorship.'
    _l 25 'daemon.err xray[901]: 2026/09/18 21:00:08.566622 [Info] infra/conf/serial: Reading config: &{Name:/etc/gatygo/xray.json Format:json}'
    _l 24 'daemon.err xray[901]: 2026/09/18 21:00:09.663598 [Warning] core: Xray 26.9.9 started'
    _l 1 'daemon.info procd: Instance gatygo::xray s in a crash loop 6 crashes, 2 seconds since last crash'
} > "$SYSLOG_STUB_FILE"
assert_eq "xray: 2026/09/18 21:00:03 [Error] transport/internet: first
xray: fatal error: runtime: out of memory
kernel: Out of memory: Killed process 900 (xray) total-vm:1300000kB, anon-rss:61000kB" "$(gatygo_crash_lines 5)" "xray's lines and the kernel's verdict on it, in order; the start-up banner of the restarts says nothing"
assert_eq "2" "$(gatygo_crash_lines 2 | wc -l | tr -d ' ')" "no more than asked for"

# --- block: the moment, the exit code and the lines are kept; the home network stays closed
printf "SERVER='1.1.1.1'\nNORESOLV=''\n" > "$GATYGO_STATE/dnsmasq.backup"
UBUS_STUB_CRASHED=1 gatygo_on_crash 2>/dev/null
assert_eq "137 0" "$(_gatygo_env_get "$GATYGO_RUN/crash.env" CODE) $(_gatygo_env_get "$GATYGO_RUN/crash.env" DIRECT)" "the record: xray's exit code, not let out"
assert_exit 0 "the record has its time" sh -c "[ \"\$(sed -n \"s/^TIME='\\(.*\\)'\$/\\1/p\" '$GATYGO_RUN/crash.env')\" -gt 1700000000 ]"
assert_eq "3" "$(wc -l < "$GATYGO_RUN/crash.log" | tr -d ' ')" "the lines are kept next to it"
assert_exit 0 "kept in the run dir (tmpfs): a reboot starts afresh" test -s "$GATYGO_RUN/crash.env"
assert_eq "" "$(cat "$tmp/fw.log")" "block: the firewall rules stay"
assert_exit 0 "block: the router's DNS settings stay" test -f "$GATYGO_STATE/dnsmasq.backup"
assert_eq "1" "$(grep -c ' gatygo\[[0-9]*\]: .*\[error\] xray quit .*exit code 137.*no internet' "$SYSLOG_STUB_FILE")" "the log says what happened and what it means at home"

# --- direct: the same record, and the home network goes back to the regular internet
uci set gatygo.main.on_crash=direct
UBUS_STUB_CRASHED=1 gatygo_on_crash 2>/dev/null
assert_eq "137 1" "$(_gatygo_env_get "$GATYGO_RUN/crash.env" CODE) $(_gatygo_env_get "$GATYGO_RUN/crash.env" DIRECT)" "the record says the network was let out"
assert_eq "1" "$(grep -c '^nft delete table inet gatygo' "$tmp/fw.log")" "direct: the nft table is removed"
assert_eq "1" "$(grep -c '^ip rule del fwmark 0x1' "$tmp/fw.log")" "direct: the policy rule is removed"
assert_exit 1 "direct: the router's DNS settings are put back" test -f "$GATYGO_STATE/dnsmasq.backup"
assert_eq "1" "$(grep -c ' gatygo\[[0-9]*\]: .*\[error\] xray quit .*regular internet' "$SYSLOG_STUB_FILE")" "the log says the network was let out"

# --- status: the record is a part of it while xray is down, and only then
CLI=/src/gatygo/files/gatygo
_st=$(UBUS_STUB_CRASHED=1 sh "$CLI" status)
assert_eq "137 true 3" "$(printf '%s' "$_st" | jq -r '"\(.crashed) \(.crash.direct) \(.crash.log | split("\n") | length)"')" "cli: crashed, let out, with the lines"
assert_exit 0 "cli: and the time" sh -c "printf '%s' '$(printf '%s' "$_st" | jq -c .crash.time)' | grep -q '^[0-9]\{10\}\$'"
assert_eq "null" "$(UBUS_STUB_RUNNING=1 sh "$CLI" status | jq -c .crash)" "cli: a running VPN has no crash to show"
assert_eq "null" "$(sh "$CLI" status | jq -c .crash)" "cli: neither has a stopped one"
rm -f "$GATYGO_RUN/crash.env" "$GATYGO_RUN/crash.log"
assert_eq "137 null" "$(UBUS_STUB_CRASHED=1 sh "$CLI" status | jq -r '"\(.crashed) \(.crash)"')" "cli: crashed with nothing noted (the watcher was not there) is still crashed"

# --- a start or a stop begins afresh
gatygo_crash_record 1 0
gatygo_crash_clear
assert_exit 1 "clear removes the record" test -e "$GATYGO_RUN/crash.env"
assert_exit 1 "and the lines" test -e "$GATYGO_RUN/crash.log"

rm -rf "$tmp"
report
