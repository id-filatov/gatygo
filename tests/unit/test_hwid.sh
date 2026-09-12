#!/bin/sh
. "$(dirname "$0")/../lib.sh"
. "$GATYGO_LIB/hwid.sh"

# sha256("ABC123" + "aa:bb:cc:dd:ee:ff") starts with bc83bbb0a59c304dc20556eb7558c6e4
assert_eq "bc83bbb0a59c304dc20556eb7558c6e4" "$(gatygo_hwid_generate ABC123 aa:bb:cc:dd:ee:ff)" \
    "hwid is the first 32 hex of sha256(serial + mac)"
_h=$(gatygo_hwid_generate other-serial 00:11:22:33:44:55)
assert_eq "32" "${#_h}" "hwid is always 32 chars"
assert_exit 0 "generated hwid passes the panel regex" gatygo_hwid_valid "$_h"

assert_exit 0 "10 alnum chars are valid" gatygo_hwid_valid abcdefghij
assert_exit 0 "'=' and '-' are allowed" gatygo_hwid_valid "abc-def=ghi=="
assert_exit 1 "9 chars are too short" gatygo_hwid_valid abcdefghi
assert_exit 1 "65 chars are too long" gatygo_hwid_valid "$(printf 'a%.0s' $(seq 1 65))"
assert_exit 1 "':' is not allowed" gatygo_hwid_valid "aa:bb:cc:dd:ee:ff:00"
assert_exit 1 "empty is invalid" gatygo_hwid_valid ""

report
