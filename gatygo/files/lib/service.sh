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

# gatygo_log_tail N — last N lines of the system log that belong to us: xray's console (procd
# relays it, tag xray) and gatygo_log (tag gatygo). A logread line is "Day Mon D HH:MM:SS YYYY
# facility.prio tag[pid]: message"; the tag is matched in that position only, and the six
# fields before it are cut. Nothing of ours is written anywhere else: logd's ring buffer bounds
# the memory.
gatygo_log_tail() {
    logread | grep -E '^([^ ]+ +){6}(gatygo|xray)(\[[0-9]+\])?: ' | tail -n "$1" \
        | sed -E 's/^([^ ]+ +){6}(gatygo|xray)(\[[0-9]+\])?: /\2: /'
}

# gatygo_update_lock — take $GATYGO_RUN/update.lock (a directory: mkdir is atomic). Exit 1 when a
# live process holds it; a lock left by a dead process is taken over.
gatygo_update_lock() {
    mkdir -p "$GATYGO_RUN"
    _gatygo_l=$GATYGO_RUN/update.lock
    if ! mkdir "$_gatygo_l" 2>/dev/null; then
        _gatygo_p=$(cat "$_gatygo_l/pid" 2>/dev/null)
        [ -n "$_gatygo_p" ] && kill -0 "$_gatygo_p" 2>/dev/null && return 1
        rm -rf "$_gatygo_l"
        mkdir "$_gatygo_l" 2>/dev/null || return 1
    fi
    echo $$ > "$_gatygo_l/pid"
}

gatygo_update_unlock() {
    rm -rf "$GATYGO_RUN/update.lock"
}

# gatygo_updating — exit 0 iff an update holds the lock and its process is alive
gatygo_updating() {
    _gatygo_p=$(cat "$GATYGO_RUN/update.lock/pid" 2>/dev/null)
    [ -n "$_gatygo_p" ] && kill -0 "$_gatygo_p" 2>/dev/null
}

# gatygo_next_update HOURS [NOW] — epoch of the next cron slot written by gatygo_cron_sync:
# every HOURS hours on the hour counted from local midnight (`0 */H`), or 03:00 daily when
# HOURS >= 24.
gatygo_next_update() {
    _gatygo_h=$1 _gatygo_now=${2:-$(date +%s)}
    _gatygo_z=$(date +%z)                       # e.g. +0300
    _gatygo_zh=${_gatygo_z#?}; _gatygo_zh=${_gatygo_zh%??}; _gatygo_zm=${_gatygo_z#???}
    _gatygo_off=$(( ${_gatygo_zh#0} * 3600 + ${_gatygo_zm#0} * 60 ))
    case $_gatygo_z in -*) _gatygo_off=$(( -_gatygo_off )) ;; esac
    _gatygo_sod=$(( (_gatygo_now + _gatygo_off) % 86400 ))
    if [ "$_gatygo_h" -ge 24 ]; then
        _gatygo_wait=$(( (3 * 3600 - _gatygo_sod + 86400) % 86400 ))
        [ "$_gatygo_wait" -gt 0 ] || _gatygo_wait=86400
    else
        _gatygo_slot=$(( _gatygo_h * 3600 ))
        _gatygo_wait=$(( _gatygo_slot - _gatygo_sod % _gatygo_slot ))
        # the */H sequence restarts at midnight
        [ $(( _gatygo_sod + _gatygo_wait )) -le 86400 ] || _gatygo_wait=$(( 86400 - _gatygo_sod ))
    fi
    echo $(( _gatygo_now + _gatygo_wait ))
}

# gatygo_proc_uptime PID — seconds since the process started (from /proc; CLK_TCK is 100 on Linux)
gatygo_proc_uptime() {
    _gatygo_up=$(cut -d' ' -f1 "$GATYGO_SYSROOT/proc/uptime" 2>/dev/null); _gatygo_up=${_gatygo_up%.*}
    _gatygo_st=$(awk '{print $22}' "$GATYGO_SYSROOT/proc/$1/stat" 2>/dev/null)
    [ -n "$_gatygo_up" ] && [ -n "$_gatygo_st" ] || return 1
    echo $(( _gatygo_up - _gatygo_st / 100 ))
}

gatygo_xray_version() {
    xray version 2>/dev/null | sed -n '1s/^Xray \([^ ]*\).*/\1/p'
}
