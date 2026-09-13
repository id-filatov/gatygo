#!/bin/sh
# Service-side helpers: procd instance state, the cron line for periodic updates, log rotation.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"

# gatygo_xray_running — exit 0 iff procd runs the `xray` instance of service `gatygo`
gatygo_xray_running() {
    ubus call service list '{"name":"gatygo"}' 2>/dev/null | jq -e '.gatygo.instances.xray.running == true' >/dev/null 2>&1
}

gatygo_xray_pid() {
    ubus call service list '{"name":"gatygo"}' 2>/dev/null | jq -r '.gatygo.instances.xray.pid // empty' 2>/dev/null
}

# gatygo_update_interval_hours — UCI update_interval → profile-update-interval header → 12; minimum 1
gatygo_update_interval_hours() {
    _gatygo_h=$GATYGO_UPDATE_INTERVAL
    case $_gatygo_h in '' | *[!0-9]*) _gatygo_h=$(_gatygo_env_get "$GATYGO_STATE/headers.env" GATYGO_UPDATE_INTERVAL 2>/dev/null) ;; esac
    case $_gatygo_h in '' | *[!0-9]*) _gatygo_h=12 ;; esac
    [ "$_gatygo_h" -ge 1 ] || _gatygo_h=1
    printf '%s\n' "$_gatygo_h"
}

_gatygo_cron_restart() {
    _gatygo_i=${GATYGO_CRON_INIT:-/etc/init.d/cron}
    [ -x "$_gatygo_i" ] && "$_gatygo_i" restart >/dev/null 2>&1
    return 0
}

# gatygo_cron_sync HOURS — make the crontab carry exactly one `# gatygo` line for the interval
gatygo_cron_sync() {
    _gatygo_f=${GATYGO_CRONTAB:-/etc/crontabs/root}
    if [ "$1" -ge 24 ]; then
        _gatygo_line="0 3 * * * /usr/bin/gatygo update # gatygo"
    else
        _gatygo_line="0 */$1 * * * /usr/bin/gatygo update # gatygo"
    fi
    mkdir -p "$(dirname "$_gatygo_f")"
    touch "$_gatygo_f"
    grep -qxF "$_gatygo_line" "$_gatygo_f" && return 0
    grep -v '# gatygo$' "$_gatygo_f" > "$_gatygo_f.tmp"
    echo "$_gatygo_line" >> "$_gatygo_f.tmp"
    mv "$_gatygo_f.tmp" "$_gatygo_f"
    _gatygo_cron_restart
}

# gatygo_cron_remove — drop our line; restart cron only if something was removed
gatygo_cron_remove() {
    _gatygo_f=${GATYGO_CRONTAB:-/etc/crontabs/root}
    [ -f "$_gatygo_f" ] && grep -q '# gatygo$' "$_gatygo_f" || return 0
    grep -v '# gatygo$' "$_gatygo_f" > "$_gatygo_f.tmp"
    mv "$_gatygo_f.tmp" "$_gatygo_f"
    _gatygo_cron_restart
}

# gatygo_log_rotate — keep the last 256 KB once the log exceeds 512 KB; truncates in place so
# xray's open file descriptor (O_APPEND) keeps working
gatygo_log_rotate() {
    [ -f "$GATYGO_LOG" ] || return 0
    [ "$(wc -c < "$GATYGO_LOG")" -gt 524288 ] || return 0
    tail -c 262144 "$GATYGO_LOG" > "$GATYGO_LOG.tmp" && cat "$GATYGO_LOG.tmp" > "$GATYGO_LOG"
    rm -f "$GATYGO_LOG.tmp"
}
