#!/bin/sh
# xray quit by itself and procd no longer restarts it (after 5 tries it notifies
# `instance.fail` on its ubus object). `gatygo watch`, the service's second instance, waits for
# that and calls gatygo_on_crash: note when and how it happened with the last lines worth
# reading, and treat the home network as the on_crash setting says. block (the default): the
# firewall rules stay, nothing leaves the house around the VPN, and nothing leaves it at all.
# direct: the rules and the DNS settings are taken back, the house is on the regular internet.
# Either way procd keeps the dead instance, so the page shows what happened until Start or Stop.

. "${GATYGO_LIB:-/usr/lib/gatygo}/service.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/firewall.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/dns.sh"

# gatygo_watch_line LINE — exit 0 iff LINE of `ubus subscribe service` says procd gave up on
# gatygo's xray
gatygo_watch_line() {
    case $1 in
        *'"instance.fail"'*'"service":"gatygo"'*'"instance":"xray"'*) return 0 ;;
    esac
    return 1
}

# gatygo_crash_lines N — the last N lines of the system log that may say why: xray's own from the
# last 3 minutes (the crash loop takes about one; an older error has nothing to do with it)
# without the balancer's failed probes and the banner of every restart, and the kernel killing
# xray for memory. `logread -t` puts the time in seconds in the 6th field.
gatygo_crash_lines() {
    logread -t | awk -v min="$(( $(date +%s) - 180 ))" '{ t = $6; gsub(/[^0-9.]/, "", t); if (t + 0 >= min) print }' \
        | grep -E '^([^ ]+ +){7}(xray(\[[0-9]+\])?: |kernel: .*Out of memory: Killed process [0-9]+ \(xray\))' \
        | grep -v -e ' app/observatory/[a-z]*: error ping ' -e ': Xray [0-9][^ ]* (' -e ': A unified platform ' \
            -e ' infra/conf/serial: Reading config' -e ' core: Xray [^ ]* started$' | tail -n "$1" \
        | sed -E 's/^([^ ]+ +){7}(xray|kernel)(\[[0-9]+\])?: (\[ *[0-9.]+\] )?/\2: /'
}

# gatygo_crash_record CODE DIRECT — keep the moment, xray's exit code, whether the home network
# was let out (1) or not (0), and the lines. In the run dir: a reboot starts afresh.
gatygo_crash_record() {
    mkdir -p "$GATYGO_RUN"
    gatygo_crash_lines 5 > "$GATYGO_RUN/crash.log"
    {
        echo "TIME=$(gatygo_shquote "$(date +%s)")"
        echo "CODE=$(gatygo_shquote "$1")"
        echo "DIRECT=$(gatygo_shquote "$2")"
    } > "$GATYGO_RUN/crash.env.tmp" && mv "$GATYGO_RUN/crash.env.tmp" "$GATYGO_RUN/crash.env"
}

gatygo_crash_clear() {
    rm -f "$GATYGO_RUN/crash.env" "$GATYGO_RUN/crash.log"
}

# gatygo_on_crash — procd gave up on xray
gatygo_on_crash() {
    gatygo_load_config
    _gatygo_code=$(gatygo_xray_crashed)
    if [ "$GATYGO_ON_CRASH" = direct ]; then
        gatygo_dns_restore
        gatygo_fw_remove
        gatygo_crash_record "${_gatygo_code:-0}" 1
        gatygo_log error "xray quit by itself and is not restarted any more (exit code ${_gatygo_code:-unknown}); the home network is on the regular internet until the VPN is started again"
    else
        gatygo_crash_record "${_gatygo_code:-0}" 0
        gatygo_log error "xray quit by itself and is not restarted any more (exit code ${_gatygo_code:-unknown}); the home network has no internet until the VPN is started again or turned off"
    fi
}
