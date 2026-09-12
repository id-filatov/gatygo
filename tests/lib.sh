#!/bin/sh
# Minimal assertion helpers for POSIX sh tests. Source this file, call `report` at the end.
# Tests must not use `set -e`: assert_exit relies on non-zero exit codes.
_t_pass=0
_t_fail=0

_t_ok() { _t_pass=$((_t_pass + 1)); }
_t_bad() { _t_fail=$((_t_fail + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# assert_eq EXPECTED ACTUAL MESSAGE
assert_eq() {
    if [ "$1" = "$2" ]; then
        _t_ok
    else
        _t_bad "$3
  expected: $1
  actual:   $2"
    fi
}

# assert_exit CODE MESSAGE CMD... — run CMD (stdout/stderr discarded), compare its exit status
assert_exit() {
    _t_want=$1; _t_msg=$2; shift 2
    "$@" >/dev/null 2>&1
    _t_rc=$?
    if [ "$_t_rc" -eq "$_t_want" ]; then
        _t_ok
    else
        _t_bad "$_t_msg (exit $_t_rc, expected $_t_want)"
    fi
}

# report — print totals; exit status 1 if anything failed
report() {
    printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$_t_pass" "$_t_fail"
    [ "$_t_fail" -eq 0 ]
}
