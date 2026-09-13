#!/bin/sh
. "$(dirname "$0")/../lib.sh"
export GATYGO_SYSROOT="$FIXTURES/sysroot"
. "$GATYGO_LIB/config.sh"
. "$GATYGO_LIB/hwid.sh"
: > "$UCI_STUB_FILE"
gatygo_load_config

# serial-number + LAN MAC from the sysroot, NUL stripped: sha256("ABC123" + "52:54:00:12:34:56")
_expected=$(printf 'ABC12352:54:00:12:34:56' | sha256sum | cut -c1-32)
_h=$(gatygo_hwid_ensure 2>/dev/null)
assert_eq "$_expected" "$_h" "hwid generated from device-tree serial and br-lan MAC"
assert_eq "$_h" "$(uci -q get gatygo.main.hwid)" "hwid stored in UCI"
_again=$(gatygo_hwid_ensure 2>/dev/null)
assert_eq "$_h" "$_again" "second call returns the stored hwid"

# a stored valid hwid is never regenerated, even if the hardware facts differ
uci set gatygo.main.hwid=keepme-keepme-1234
assert_eq "keepme-keepme-1234" "$(gatygo_hwid_ensure 2>/dev/null)" "stored valid hwid is kept"

# an invalid stored value is replaced
uci set gatygo.main.hwid="bad:value"
assert_eq "$_expected" "$(gatygo_hwid_ensure 2>/dev/null)" "invalid stored hwid is regenerated"

# no device-tree serial -> board_name is the serial
_tmp=$(mktemp -d); cp -r "$FIXTURES/sysroot/." "$_tmp/"; rm "$_tmp/proc/device-tree/serial-number"
uci delete gatygo.main.hwid
_expected2=$(printf 'qemu-qemu-virtual-machine52:54:00:12:34:56' | sha256sum | cut -c1-32)
assert_eq "$_expected2" "$(GATYGO_SYSROOT=$_tmp gatygo_hwid_ensure 2>/dev/null)" "board_name used when no serial-number"
rm -rf "$_tmp"

report
