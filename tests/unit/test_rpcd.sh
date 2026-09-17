#!/bin/sh
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
RPCD=/src/luci-app-gatygo/root/usr/libexec/rpcd/gatygo
export GATYGO_BIN=/src/tests/stubs/gatygo-cli GATYGO_CLI_LOG="$tmp/calls" GATYGO_CLI_UPDATE_MARK="$tmp/updated"
: > "$GATYGO_CLI_LOG"
call() { _m=$1; shift; printf '%s' "${1:-{\}}" | sh "$RPCD" call "$_m"; }

assert_eq '["connect","log","nodes","select","status","update"]' "$(sh "$RPCD" list | jq -c 'keys')" "list names the six methods"
assert_eq "32" "$(sh "$RPCD" list | jq '.log.lines')" "log declares a numeric argument"
assert_eq "true" "$(call status | jq .running)" "status passes the CLI JSON through"
assert_eq "proxy" "$(call nodes | jq -r '.nodes[0].tag')" "nodes passes the CLI JSON through"
assert_eq "3" "$(call log '{"lines":3}' | jq -r .log | grep -c .)" "log honours lines"
assert_eq "200" "$(call log '{}' | jq -r .log | grep -c .)" "log defaults to 200"
assert_eq "200" "$(call log '{"lines":"abc"}' | jq -r .log | grep -c .)" "non-numeric lines -> default"
assert_eq "true" "$(call update | jq .started)" "update starts"
assert_exit 1 "update returns before the CLI finishes" test -e "$GATYGO_CLI_UPDATE_MARK"
sleep 1.5
assert_exit 0 "the backgrounded update did run" test -e "$GATYGO_CLI_UPDATE_MARK"
assert_eq "false" "$(GATYGO_CLI_UPDATING_RC=0 call update | jq .started)" "update refused while one runs"
assert_eq "1" "$(grep -c '^update$' "$GATYGO_CLI_LOG")" "the CLI was started exactly once"
_sel=$(call select '{"profile":"📍 Bravo"}')
assert_eq "ok" "$(printf '%s' "$_sel" | jq -r .result)" "select reports the result"
assert_eq "applied" "$(printf '%s' "$_sel" | jq -r .code)" "select reports the result code"
assert_eq "🌐 Auto" "$(printf '%s' "$_sel" | jq -r .profile)" "select reports the profile in use"
assert_eq "1" "$(grep -c '^select 📍 Bravo$' "$GATYGO_CLI_LOG")" "select passed the profile verbatim"
assert_eq "profile required" "$(call select '{}' | jq -r .error)" "select without a profile"

# --- connect: the link goes to the CLI verbatim, the call returns before the first download ends
assert_eq "true" "$(call connect '{"url":"https://panel.example.com/sub/a b&c"}' | jq .started)" "connect starts"
assert_exit 1 "connect returns before the CLI finishes" test -e "$GATYGO_CLI_UPDATE_MARK.connect"
sleep 1.5
assert_exit 0 "the backgrounded connect did run" test -e "$GATYGO_CLI_UPDATE_MARK.connect"
assert_eq "1" "$(grep -c '^connect https://panel.example.com/sub/a b&c$' "$GATYGO_CLI_LOG")" "connect passed the link verbatim"
assert_eq "link required" "$(call connect '{"url":"ftp://x"}' | jq -r .error)" "connect wants an http(s) link"
assert_eq "unknown method" "$(call bogus | jq -r .error)" "unknown method"

rm -rf "$tmp"
report
