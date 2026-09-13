#!/bin/sh
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state" GATYGO_LOG="$tmp/gatygo.log" GATYGO_CRONTAB="$tmp/crontabs/root" \
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

# --- log rotation: >512 KB -> last 256 KB kept, in place
head -c 600000 /dev/zero | tr '\0' 'x' > "$GATYGO_LOG"; printf '\nLAST LINE\n' >> "$GATYGO_LOG"
gatygo_log_rotate
_size=$(stat -c %s "$GATYGO_LOG")
assert_exit 0 "log truncated to at most 256 KB" test "$_size" -le 262144
assert_eq "LAST LINE" "$(tail -n 1 "$GATYGO_LOG")" "tail of the log kept"
printf 'small\n' > "$GATYGO_LOG"; gatygo_log_rotate
assert_eq "small" "$(cat "$GATYGO_LOG")" "small log untouched"

rm -rf "$tmp"
report
