#!/bin/sh
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state" GATYGO_CRONTAB="$tmp/crontabs/root" \
       GATYGO_CRON_INIT=/src/tests/stubs/cron-init GATYGO_CRON_LOG="$tmp/cron.log"
mkdir -p "$GATYGO_STATE"; : > "$UCI_STUB_FILE"; : > "$GATYGO_CRON_LOG"
. "$GATYGO_LIB/config.sh"
. "$GATYGO_LIB/service.sh"
gatygo_load_config

# --- interval: UCI > header > 12, minimum 1
assert_eq "12" "$(gatygo_update_interval_hours)" "default 12h"
printf "GATYGO_UPDATE_INTERVAL='3'\n" > "$GATYGO_STATE/headers.env"
assert_eq "3" "$(gatygo_update_interval_hours)" "from the subscription header"
uci set gatygo.main.update_interval=6; gatygo_load_config
assert_eq "6" "$(gatygo_update_interval_hours)" "UCI wins"
uci set gatygo.main.update_interval=0; gatygo_load_config
assert_eq "1" "$(gatygo_update_interval_hours)" "minimum 1h"
uci set gatygo.main.update_interval=abc; gatygo_load_config
assert_eq "3" "$(gatygo_update_interval_hours)" "garbage in UCI -> header"

# --- cron line
gatygo_cron_sync 6
assert_eq "0 */6 * * * /usr/bin/gatygo update # gatygo" "$(cat "$GATYGO_CRONTAB")" "every 6 hours"
assert_eq "restart" "$(cat "$GATYGO_CRON_LOG")" "cron restarted after the change"
: > "$GATYGO_CRON_LOG"
gatygo_cron_sync 6
assert_eq "" "$(cat "$GATYGO_CRON_LOG")" "no restart when the line is already right"
printf '5 4 * * * /bin/echo keep\n' >> "$GATYGO_CRONTAB"
gatygo_cron_sync 24
assert_eq "5 4 * * * /bin/echo keep
0 3 * * * /usr/bin/gatygo update # gatygo" "$(cat "$GATYGO_CRONTAB")" "24h+ becomes daily at 03:00; foreign lines kept"
gatygo_cron_remove
assert_eq "5 4 * * * /bin/echo keep" "$(cat "$GATYGO_CRONTAB")" "only our line removed"
: > "$GATYGO_CRON_LOG"
gatygo_cron_remove
assert_eq "" "$(cat "$GATYGO_CRON_LOG")" "remove without our line is a no-op"

# --- gatygo_log_tail N: xray (relayed by procd) and gatygo lines from the system log, prefix cut to the tag
cat > "$SYSLOG_STUB_FILE" <<'SYSLOG'
Wed Sep 16 14:00:00 2026 cron.err crond[3146]: USER root pid 6746 cmd /usr/bin/gatygo update
Wed Sep 16 14:00:01 2026 daemon.info xray[2845]: 2026/09/16 14:00:01.1 [Warning] core: Xray 26.3.27 started
Wed Sep 16 14:00:02 2026 daemon.info gatygo[6746]: 2026-09-16T14:00:02 [info] subscription updated
Wed Sep 16 14:00:03 2026 daemon.warn odhcpd[2148]: A default route is present but gatygo[1]: is not a tag
Wed Sep 16 14:00:04 2026 daemon.err xray: 2026/09/16 14:00:04.2 [Error] app/dns: failed
SYSLOG
assert_eq "xray: 2026/09/16 14:00:01.1 [Warning] core: Xray 26.3.27 started
gatygo: 2026-09-16T14:00:02 [info] subscription updated
xray: 2026/09/16 14:00:04.2 [Error] app/dns: failed" "$(gatygo_log_tail 200)" "only the xray and gatygo tags, with or without pid, syslog prefix cut"
assert_eq "xray: 2026/09/16 14:00:04.2 [Error] app/dns: failed" "$(gatygo_log_tail 1)" "last N lines"

# --- update lock: a directory with the holder's pid
export GATYGO_RUN="$tmp/run"
assert_exit 0 "lock taken" gatygo_update_lock
assert_eq "$$" "$(cat "$GATYGO_RUN/update.lock/pid")" "lock records the pid"
assert_exit 0 "updating while held by a live pid" gatygo_updating
assert_exit 1 "second lock refused while held" gatygo_update_lock
gatygo_update_unlock
assert_exit 1 "not updating after unlock" gatygo_updating
mkdir -p "$GATYGO_RUN/update.lock"; echo 999999 > "$GATYGO_RUN/update.lock/pid"
assert_exit 1 "stale lock (dead pid) does not count as updating" gatygo_updating
assert_exit 0 "stale lock is taken over" gatygo_update_lock
gatygo_update_unlock

# --- next update: cron slots in local time (tests run in UTC)
export TZ=UTC
assert_eq "1004400" "$(gatygo_next_update 3 1000000)" "13:46:40 + 3h slots -> 15:00"
assert_eq "1047600" "$(gatygo_next_update 24 1000000)" "daily -> next 03:00"
assert_eq "1008000" "$(gatygo_next_update 1 1006000)" "15:26:40 + 1h slots -> 16:00"
assert_eq "1036800" "$(gatygo_next_update 5 1024000)" "20:26:40 + 5h slots -> midnight (cron restarts the */5 sequence)"

# --- process uptime from /proc, xray version
export GATYGO_SYSROOT="$FIXTURES/sysroot"
assert_eq "50000" "$(gatygo_proc_uptime 4242)" "uptime = system uptime - start time"
assert_exit 1 "unknown pid -> exit 1" gatygo_proc_uptime 1
# the test image's xray is the pinned core (tools/pin-core.sh moves both)
assert_eq "$(sed -n 's#.*  v\(.*\)/.*#\1#p' "$GATYGO_LIB/core.pin" | head -n 1)" "$(gatygo_xray_version)" "xray version parsed, and it is the pinned one"

# --- CLI: updating / log
CLI=/src/gatygo/files/gatygo
printf 'Wed Sep  9 14:00:0%s 2026 %s\n' 1 'daemon.info xray[1]: one' 2 'daemon.info gatygo[2]: two' 3 'daemon.err xray[1]: three' > "$SYSLOG_STUB_FILE"
assert_eq "gatygo: two
xray: three" "$(GATYGO_LIB=$GATYGO_LIB sh "$CLI" log 2)" "log N prints the last N lines"
assert_eq "3" "$(GATYGO_LIB=$GATYGO_LIB sh "$CLI" log | wc -l | tr -d ' ')" "log defaults to the last 200 lines"
# the balancer's health probes fail by the dozen per hour on a large subscription: not shown
printf 'Wed Sep  9 14:00:0%s 2026 %s\n' 4 'daemon.info xray[1]: 2026/09/09 14:00:04.1 [Warning] app/observatory/burst: error ping https://probe.example.com/generate_204 with proxy-7: context deadline exceeded' \
    5 'daemon.info xray[1]: 2026/09/09 14:00:05.1 [Warning] core: Xray started' >> "$SYSLOG_STUB_FILE"
assert_eq "xray: three
xray: 2026/09/09 14:00:05.1 [Warning] core: Xray started" "$(GATYGO_LIB=$GATYGO_LIB sh "$CLI" log 2)" "log skips the balancer's failed probes, and N counts what is shown"
assert_exit 1 "cli: not updating" sh "$CLI" updating
gatygo_update_lock
assert_exit 0 "cli: updating while locked" sh "$CLI" updating
gatygo_update_unlock

# --- CLI: connect (the first run from the page) stores the link, enables the service, starts it
export GATYGO_INIT=/src/tests/stubs/gatygo-init GATYGO_INIT_LOG="$tmp/init.log"
: > "$GATYGO_INIT_LOG"
assert_exit 0 "cli: connect" sh "$CLI" connect "https://panel.example.com/sub/abc"
assert_eq "https://panel.example.com/sub/abc" "$(uci -q get gatygo.main.sub_url)" "connect stores the link"
assert_eq "1" "$(uci -q get gatygo.main.enabled)" "connect enables the service"
assert_eq "enable start" "$(tr '\n' ' ' < "$GATYGO_INIT_LOG" | sed 's/ $//')" "connect enables and starts the init script"
assert_exit 1 "cli: connect refuses what is not a link" sh "$CLI" connect "hello"
assert_eq "https://panel.example.com/sub/abc" "$(uci -q get gatygo.main.sub_url)" "and leaves the stored link alone"

rm -rf "$tmp"
report
