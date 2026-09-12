#!/bin/sh
. "$(dirname "$0")/../lib.sh"
. "$GATYGO_LIB/common.sh"

# gatygo_log: stderr only, "<timestamp> [level] message"
assert_eq "" "$(gatygo_log info hello 2>/dev/null)" "log writes nothing to stdout"
_out=$(gatygo_log warn hello world 2>&1)
assert_eq "[warn] hello world" "${_out#* }" "log line is '<timestamp> [level] message'"

# gatygo_shquote: output is a single-quoted literal that round-trips through the shell
_in="it's \"quoted\" \$HOME \`x\` \\ done"
eval "_back=$(gatygo_shquote "$_in")"
assert_eq "$_in" "$_back" "quotes, dollar, backtick and backslash survive"
_nl=$(printf 'line1\nline2')
eval "_back=$(gatygo_shquote "$_nl")"
assert_eq "$_nl" "$_back" "newline survives"
assert_eq "''" "$(gatygo_shquote "")" "empty string quotes to ''"

report
