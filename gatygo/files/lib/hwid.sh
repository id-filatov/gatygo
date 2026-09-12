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
