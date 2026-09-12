#!/usr/bin/env python3
"""Write small geosite.dat / geoip.dat test files with the categories tests/fixtures/subscription.json uses.

Usage: tools/gen-geodat.py OUT_DIR

The files follow xray's GeoSiteList / GeoIPList protobuf messages, encoded by hand so no protobuf
package is needed. The output is deterministic.
"""
import ipaddress
import os
import sys

# code -> [(domain type, value)]; types: 0 plain, 1 regex, 2 domain (with subdomains), 3 full
GEOSITE = {
    "ADS": [(2, "ads.example.com"), (2, "tracker.example.net")],
    "LOCAL": [(2, "example.org"), (3, "portal.example.org")],
    "PRIVATE": [(3, "localhost"), (2, "local"), (2, "lan")],
    "STREAMING": [(2, "video.example.com"), (2, "cdn.example.net")],
}

GEOIP = {
    "LOCAL": ["192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"],
    "PRIVATE": ["10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
                "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10"],
}


def varint(n):
    out = bytearray()
    while True:
        b, n = n & 0x7F, n >> 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def field_bytes(num, data):
    return varint(num << 3 | 2) + varint(len(data)) + data


def field_varint(num, value):
    return varint(num << 3) + varint(value) if value else b""


def geosite_list():
    entries = b""
    for code, domains in sorted(GEOSITE.items()):
        body = field_bytes(1, code.encode())
        for dtype, value in domains:
            body += field_bytes(2, field_varint(1, dtype) + field_bytes(2, value.encode()))
        entries += field_bytes(1, body)
    return entries


def geoip_list():
    entries = b""
    for code, cidrs in sorted(GEOIP.items()):
        body = field_bytes(1, code.encode())
        for cidr in cidrs:
            net = ipaddress.ip_network(cidr)
            body += field_bytes(2, field_bytes(1, net.network_address.packed) + field_varint(2, net.prefixlen))
        entries += field_bytes(1, body)
    return entries


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "geosite.dat"), "wb") as f:
        f.write(geosite_list())
    with open(os.path.join(out, "geoip.dat"), "wb") as f:
        f.write(geoip_list())


if __name__ == "__main__":
    main()
