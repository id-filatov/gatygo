#!/bin/sh
# Router hardware ID sent as the x-hwid subscription header.
# Generated once and stored in UCI; regenerating it costs a slot in the panel's device limit.

# gatygo_hwid_generate SERIAL MAC — print the first 32 hex chars of sha256(SERIAL + MAC).
gatygo_hwid_generate() {
    printf '%s%s' "$1" "$2" | sha256sum | cut -c1-32
}

# gatygo_hwid_valid HWID — exit 0 iff HWID matches the panel's regex /^[a-zA-Z0-9=-]{10,64}$/
# (the panel ignores anything else as if no hwid was sent).
gatygo_hwid_valid() {
    printf '%s' "$1" | grep -Eq '^[a-zA-Z0-9=-]{10,64}$'
}

# gatygo_hwid_ensure — print the router's hwid; generate and store it in UCI when missing or invalid.
# Serial = /proc/device-tree/serial-number (NUL-terminated) or board_name; MAC = first LAN device.
# Requires gatygo_load_config (GATYGO_LAN_IFACES, GATYGO_SYSROOT).
gatygo_hwid_ensure() {
    _gatygo_h=$(uci -q get gatygo.main.hwid 2>/dev/null)
    if ! gatygo_hwid_valid "$_gatygo_h"; then
        _gatygo_serial=$(tr -d '\000' < "$GATYGO_SYSROOT/proc/device-tree/serial-number" 2>/dev/null)
        [ -n "$_gatygo_serial" ] || _gatygo_serial=$(cat "$GATYGO_SYSROOT/tmp/sysinfo/board_name" 2>/dev/null)
        _gatygo_dev=${GATYGO_LAN_IFACES%% *}
        _gatygo_mac=$(cat "$GATYGO_SYSROOT/sys/class/net/${_gatygo_dev:-br-lan}/address" 2>/dev/null)
        _gatygo_h=$(gatygo_hwid_generate "$_gatygo_serial" "$_gatygo_mac")
        uci set gatygo.main.hwid="$_gatygo_h" && uci commit gatygo
        gatygo_log info "generated a new hwid (device limit on the panel counts a new device)"
    fi
    printf '%s\n' "$_gatygo_h"
}
