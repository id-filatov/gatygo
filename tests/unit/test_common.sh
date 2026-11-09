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

# gatygo_http_url: an http(s) address without spaces or control characters, or nothing
for _u in https://example.com/sub HTTP://example.com https://t.me/example_support; do
    assert_eq "$_u" "$(gatygo_http_url "$_u")" "http_url accepts $_u"
done
_tab=$(printf 'https://example.com/a\tb')
for _u in 'javascript:alert(1)' 'tg://resolve?domain=x' ftp://example.com //example.com https:// 'https://exa mple.com' "$_tab" ''; do
    assert_eq "" "$(gatygo_http_url "$_u")" "http_url refuses '$_u'"
    assert_exit 1 "http_url exits 1 on '$_u'" gatygo_http_url "$_u"
done

# --- portability: OpenWrt's busybox sleep takes whole seconds only ("sleep: invalid number '0.5'")
assert_eq "" "$(grep -rn 'sleep [0-9]*\.[0-9]' /src/gatygo/files)" "no fractional sleep in the package"

report
