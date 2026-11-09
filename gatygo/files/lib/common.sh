#!/bin/sh
# Shared helpers for gatygo modules. Sourced, never executed.

# gatygo_log LEVEL MESSAGE... — one line "<timestamp> [LEVEL] MESSAGE" to stderr and to the
# system log with tag gatygo (cron, rpcd and the init script have no other visible output;
# `gatygo log` reads it back next to xray's lines). LEVEL: info | warn | error. Never fails.
# Never pass the subscription URL, user UUID or hwid here.
gatygo_log() {
    _gatygo_lvl=$1
    shift
    _gatygo_line="$(date '+%Y-%m-%dT%H:%M:%S') [$_gatygo_lvl] $*"
    printf '%s\n' "$_gatygo_line" >&2
    case $_gatygo_lvl in
        error) _gatygo_prio=err ;;
        warn) _gatygo_prio=warning ;;
        *) _gatygo_prio=info ;;
    esac
    logger -t gatygo -p "daemon.$_gatygo_prio" "$_gatygo_line" 2>/dev/null
    return 0
}

# gatygo_http_url VALUE — print VALUE and exit 0 when it is an http:// or https:// address (the
# scheme in any case) with something after it and no blank or control character; else exit 1.
# Links from the network reach the page only through this: no javascript:, data: or app schemes.
gatygo_http_url() {
    case $1 in
        [Hh][Tt][Tt][Pp]://?* | [Hh][Tt][Tt][Pp][Ss]://?*) ;;
        *) return 1 ;;
    esac
    case $1 in *[[:space:][:cntrl:]]*) return 1 ;; esac
    printf '%s\n' "$1"
}

# gatygo_shquote STR — print STR as a single-quoted POSIX shell literal, safe to source.
gatygo_shquote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
