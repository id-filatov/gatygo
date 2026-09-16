#!/bin/sh
. "$(dirname "$0")/../lib.sh"
. "$GATYGO_LIB/common.sh"

# gatygo_log: "<timestamp> [level] message" to stderr and to the system log, tag gatygo
: > "$SYSLOG_STUB_FILE"
assert_eq "" "$(gatygo_log info hello 2>/dev/null)" "log writes nothing to stdout"
: > "$SYSLOG_STUB_FILE"
_out=$(gatygo_log warn hello world 2>&1)
assert_eq "[warn] hello world" "${_out#* }" "log line is '<timestamp> [level] message'"
assert_eq "daemon.warning gatygo: $_out" "$(sed -E 's/^.* (daemon\.[a-z]+) gatygo\[[0-9]+\]: /\1 gatygo: /' "$SYSLOG_STUB_FILE")" "same line in syslog: tag gatygo, priority warning"
gatygo_log info x 2>/dev/null
gatygo_log error y 2>/dev/null
assert_eq "warning info err" "$(sed -E 's/^.* daemon\.([a-z]+) gatygo\[.*/\1/' "$SYSLOG_STUB_FILE" | tr '\n' ' ' | sed 's/ $//')" "warn/info/error -> syslog warning/info/err"
_out=$(SYSLOG_STUB_FILE=/nonexistent/dir/syslog; export SYSLOG_STUB_FILE; gatygo_log warn no syslog 2>&1)
assert_eq "[warn] no syslog" "${_out#* }" "logger failure: stderr line only, no error text"
assert_exit 0 "logger failure: exit 0" sh -c 'SYSLOG_STUB_FILE=/nonexistent/dir/syslog; export SYSLOG_STUB_FILE; . "$GATYGO_LIB/common.sh"; gatygo_log warn no syslog'

# gatygo_shquote: output is a single-quoted literal that round-trips through the shell
_in="it's \"quoted\" \$HOME \`x\` \\ done"
eval "_back=$(gatygo_shquote "$_in")"
assert_eq "$_in" "$_back" "quotes, dollar, backtick and backslash survive"
_nl=$(printf 'line1\nline2')
eval "_back=$(gatygo_shquote "$_nl")"
assert_eq "$_nl" "$_back" "newline survives"
assert_eq "''" "$(gatygo_shquote "")" "empty string quotes to ''"

report
