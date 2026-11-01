#!/bin/sh
# Addresses and subnets of the user's rules: read one, bring it to the one canonical form the page
# and the daemon share (repeats and statuses are looked up by it), tell a local network, and pick
# an address of a subnet to ask xray about. The arithmetic is awk's: jq on OpenWrt has no regex,
# and awk holds every IPv4 number up to 2^32 exactly.
#
# Canonical form: IPv4 — four numbers 0-255 without leading zeros; IPv6 — lower case, RFC 5952
# (no leading zeros in a group, the longest run of two or more zero groups as `::`, the first of
# equal ones), no embedded IPv4, no zone. A mask (/0-/32, /0-/128, no leading zeros) zeroes the
# host bits; /32 and /128 are dropped. GATYGO_RESERVED4 comes from config.sh (the caller's).

# shared by every awk program below
_GATYGO_ADDR_AWK='
function dec(s) { return s ~ /^(0|[1-9][0-9]*)$/ && length(s) <= 3 ? s + 0 : -1 }
# v4num("a.b.c.d") — the address as a number, -1 when it is not one
function v4num(s,   p, i, n, v) {
    if (split(s, p, ".") != 4) return -1
    n = 0
    for (i = 1; i <= 4; i++) { v = dec(p[i]); if (v < 0 || v > 255) return -1; n = n * 256 + v }
    return n
}
function v4str(n) {
    return sprintf("%d.%d.%d.%d", int(n / 16777216) % 256, int(n / 65536) % 256, int(n / 256) % 256, n % 256)
}
# v4net("a.b.c.d[/m]", r) — r[1] first and r[2] last address of the subnet, 0 when it is not one
function v4net(s,   p, n, m, b) {
    m = 32
    if (index(s, "/")) { split(s, p, "/"); s = p[1]; m = p[2] + 0 }
    n = v4num(s); b = 2 ^ (32 - m)
    r[1] = int(n / b) * b; r[2] = r[1] + b - 1
    return 1
}
function hexnum(s,   i, n) {
    n = 0
    for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
    return n
}
# v6groups(s, g) — the eight groups of s into g[1..8], 0 when s is not an IPv6 address
function v6groups(s, g,   i, left, right, L, R, nl, nr, k) {
    i = index(s, "::")
    if (i) {
        left = substr(s, 1, i - 1); right = substr(s, i + 2)
        if (index(right, "::")) return 0
        nl = left == "" ? 0 : split(left, L, ":")
        nr = right == "" ? 0 : split(right, R, ":")
        if (nl + nr > 7) return 0
    } else {
        nl = split(s, L, ":"); nr = 0
        if (nl != 8) return 0
    }
    for (k = 1; k <= nl; k++) if (L[k] !~ /^[0-9a-f]+$/ || length(L[k]) > 4) return 0
    for (k = 1; k <= nr; k++) if (R[k] !~ /^[0-9a-f]+$/ || length(R[k]) > 4) return 0
    for (k = 1; k <= 8; k++) g[k] = 0
    for (k = 1; k <= nl; k++) g[k] = hexnum(L[k])
    for (k = 1; k <= nr; k++) g[8 - nr + k] = hexnum(R[k])
    return 1
}
'

# gatygo_addr_norm VALUE — VALUE in the canonical form; exit 1 and nothing printed if it is not an
# address or a subnet
gatygo_addr_norm() {
    case $1 in '' | *[!0-9A-Fa-f.:/]*) return 1 ;; esac
    printf '%s\n' "$1" | awk "$_GATYGO_ADDR_AWK"'
    {
        s = tolower($0); m = -1
        n = split(s, p, "/")
        if (n > 2) exit 1
        if (n == 2) { s = p[1]; m = p[2]; if (m !~ /^(0|[1-9][0-9]*)$/ || length(m) > 3) exit 1; m += 0 }
        if (index(s, ":")) {
            if (index(s, ".") || !v6groups(s, g)) exit 1
            if (m < 0) m = 128
            if (m > 128) exit 1
            for (k = 1; k <= 8; k++) {
                b = m - (k - 1) * 16
                if (b <= 0) g[k] = 0
                else if (b < 16) g[k] = int(g[k] / 2 ^ (16 - b)) * 2 ^ (16 - b)
            }
            # the longest run of two or more zero groups, the first of equal ones
            bs = 0; bl = 1; rs = 0
            for (k = 1; k <= 9; k++) {
                if (k <= 8 && g[k] == 0) { if (!rs) rs = k; continue }
                if (rs && k - rs > bl) { bs = rs; bl = k - rs }
                rs = 0
            }
            out = ""
            for (k = 1; k <= 8; k++) {
                if (bs && k >= bs && k < bs + bl) { if (k == bs) out = out "::"; continue }
                if (out != "" && out !~ /::$/) out = out ":"
                out = out sprintf("%x", g[k])
            }
            if (m < 128) out = out "/" m
        } else {
            a = v4num(s)
            if (a < 0) exit 1
            if (m < 0) m = 32
            if (m > 32) exit 1
            b = 2 ^ (32 - m)
            out = v4str(int(a / b) * b)
            if (m < 32) out = out "/" m
        }
        print out
    }'
}

# gatygo_addr_family ADDR — 4 or 6 (ADDR canonical)
gatygo_addr_family() {
    case $1 in *:*) echo 6 ;; *) echo 4 ;; esac
}

# gatygo_addr_local ADDR — exit 0 if the whole subnet lies in the local network: GATYGO_RESERVED4
# for IPv4, fe80::/10 and fc00::/7 for IPv6 (ADDR canonical)
gatygo_addr_local() {
    awk -v a="$1" -v res="$GATYGO_RESERVED4" "$_GATYGO_ADDR_AWK"'
    BEGIN {
        m = index(a, "/") ? substr(a, index(a, "/") + 1) + 0 : -1
        if (index(a, ":")) {
            s = a; sub(/\/.*/, "", s); v6groups(s, g)
            if (m < 0) m = 128
            exit !((m >= 10 && int(g[1] / 64) == int(65152 / 64)) || (m >= 7 && int(g[1] / 512) == int(64512 / 512)))
        }
        v4net(a); s = r[1]; e = r[2]
        n = split(res, R, " ")
        for (i = 1; i <= n; i++) { v4net(R[i]); if (s >= r[1] && e <= r[2]) exit 0 }
        exit 1
    }'
}

# gatygo_addr_probe ADDR [EXCLUDE...] — IPv4 only: the first address of ADDR outside
# GATYGO_RESERVED4 and outside every EXCLUDE subnet; exit 1 if there is none
gatygo_addr_probe() {
    _gatygo_ap=$1; shift
    awk -v a="$_gatygo_ap" -v res="$GATYGO_RESERVED4" -v ex="$*" "$_GATYGO_ADDR_AWK"'
    BEGIN {
        v4net(a); c = r[1]; e = r[2]
        n = split(res " " ex, B, " ")
        for (i = 1; i <= n; i++) {
            lo[i] = 1; hi[i] = 0
            if (!index(B[i], ":")) { v4net(B[i]); lo[i] = r[1]; hi[i] = r[2] }
        }
        do {
            moved = 0
            for (i = 1; i <= n; i++) if (c >= lo[i] && c <= hi[i]) { c = hi[i] + 1; moved = 1 }
        } while (moved && c <= e)
        if (c > e) exit 1
        print v4str(c)
    }'
}
