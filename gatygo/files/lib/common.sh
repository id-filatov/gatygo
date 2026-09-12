#!/bin/sh
# Shared helpers for gatygo modules. Sourced, never executed.

# gatygo_log LEVEL MESSAGE... — one line to stderr: "<timestamp> [LEVEL] MESSAGE".
# Never pass the subscription URL, user UUID or hwid here.
gatygo_log() {
    _gatygo_lvl=$1
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$_gatygo_lvl" "$*" >&2
}

# gatygo_shquote STR — print STR as a single-quoted POSIX shell literal, safe to source.
gatygo_shquote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
