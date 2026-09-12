#!/usr/bin/env python3
"""Write the synthetic Xray-JSON subscription used by the tests to stdout.

Usage: tools/gen-fixture.py > tests/fixtures/subscription.json

22 configs: 13 profiles with a balancer (what the user picks from) followed by 9 single-server
configs without one, which the client must not offer. Transports cover VLESS REALITY over TCP
(vision) and gRPC and VLESS TLS over XHTTP; routing uses the geo categories from tools/gen-geodat.py.
All hosts are example.com/example.net, keys and ids are placeholders. The output is deterministic.
"""
import json
import sys

UUID = "00000000-0000-4000-8000-000000000000"
REALITY_KEY = "TaZ1t7htFxYjbxXzkFQz_vdueb-SBrgL_-SEcvgMdEw"
SHORT_ID = "0123456789abcdef"

# (remarks, description, transports: "t" tcp+xhttp pair, "g" grpc, "x" xhttp only)
BALANCED = [
    ("🌐 Auto", "Best server across all locations", "t" * 12),
    ("🌐 Mobile", "For mobile networks", "g" * 3),
    ("🌐 Streaming", "Streaming-friendly servers", "t" * 3),
    ("📍 Alpha", "", "t" * 2),
    ("📍 Bravo", "", "t" * 4),
    ("📍 Charlie", "", "t"),
    ("📍 Delta", "", "t" * 3),
    ("📍 Echo", "", "g" * 2),
    ("📍 Foxtrot", "", "t" * 3),
    ("📍 Golf", "", "t"),
    ("📍 Hotel", "", "t" * 2),
    ("📍 India", "", "t"),
    ("📍 Juliett", "", "t" * 2),
]
SINGLE = [
    ("⬇️ Router profiles", "Profiles below are for routers", "tcp"),
    ("🌐 Streaming | Router", "", "x"),
    ("📍 Alpha | Router", "", "x"),
    ("📍 Bravo | Router", "", "x"),
    ("📍 Charlie | Router", "", "x"),
    ("📍 Delta | Router", "", "tcp"),
    ("📍 Echo | Router", "", "x"),
    ("📍 Foxtrot | Router", "", "x"),
    ("📍 Golf | Router", "", "x"),
]

STRATEGIES = [
    {"type": "leastLoad", "settings": {"expected": 3, "baselines": ["150ms", "300ms"], "tolerance": 0.3}},
    {"type": "leastLoad", "settings": {"maxRTT": "5s", "expected": 2, "baselines": ["1s"], "tolerance": 0.3}},
    {"type": "leastPing"},
]

_counter = [0]


def next_hosts():
    n = _counter[0]
    _counter[0] += 1
    return f"relay-{n % 12 + 1}.example.com", f"node-{n % 8 + 1}.example.net"


def reality_tcp(tag):
    addr, sni = next_hosts()
    return {"tag": tag, "protocol": "vless",
            "settings": {"vnext": [{"address": addr, "port": 443,
                                    "users": [{"id": UUID, "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
            "streamSettings": {"network": "tcp", "tcpSettings": {}, "security": "reality",
                               "realitySettings": {"serverName": sni, "publicKey": REALITY_KEY,
                                                   "shortId": SHORT_ID, "fingerprint": "chrome"}}}


def reality_grpc(tag):
    addr, sni = next_hosts()
    return {"tag": tag, "protocol": "vless",
            "settings": {"vnext": [{"address": addr, "port": 443,
                                    "users": [{"id": UUID, "encryption": "none", "flow": ""}]}]},
            "streamSettings": {"network": "grpc", "grpcSettings": {"serviceName": "grpc", "authority": "", "mode": False},
                               "security": "reality",
                               "realitySettings": {"serverName": sni, "publicKey": REALITY_KEY,
                                                   "shortId": SHORT_ID, "fingerprint": "chrome"}}}


def tls_xhttp(tag):
    addr, sni = next_hosts()
    return {"tag": tag, "protocol": "vless",
            "settings": {"vnext": [{"address": addr, "port": 443,
                                    "users": [{"id": UUID, "encryption": "none", "flow": ""}]}]},
            "streamSettings": {"network": "xhttp",
                               "xhttpSettings": {"mode": "packet-up", "host": "", "path": "/xhttp/",
                                                 "extra": {"xPaddingBytes": "100-1000", "noGRPCHeader": False,
                                                           "xmux": {"maxConcurrency": "16-32", "maxConnections": 0}}},
                               "security": "tls",
                               "tlsSettings": {"serverName": sni, "fingerprint": "chrome", "alpn": ["h2", "http/1.1"]}}}


def proxies(kinds):
    out = []
    for kind in kinds:
        builders = {"t": (reality_tcp, tls_xhttp), "g": (reality_grpc,), "x": (tls_xhttp,), "tcp": (reality_tcp,)}[kind]
        for build in builders:
            out.append(build("proxy" if not out else f"proxy-{len(out) + 1}"))
    return out


INBOUNDS = [
    {"tag": "socks", "port": 10808, "listen": "127.0.0.1", "protocol": "socks",
     "settings": {"udp": True, "auth": "noauth"},
     "sniffing": {"enabled": True, "routeOnly": False, "destOverride": ["http", "tls", "quic"]}},
    {"tag": "http", "port": 10809, "listen": "127.0.0.1", "protocol": "http",
     "settings": {"allowTransparent": False},
     "sniffing": {"enabled": True, "routeOnly": False, "destOverride": ["http", "tls", "quic"]}},
]


def dns(mobile):
    if mobile:
        return {"servers": [{"address": "https://9.9.9.9/dns-query", "queryStrategy": "UseIPv4"}],
                "queryStrategy": "UseIPv4"}
    return {"hosts": {"portal.example.org": "192.0.2.10"},
            "servers": [{"address": "https://1.1.1.1/dns-query", "queryStrategy": "UseIPv4"},
                        {"address": "https://9.9.9.9/dns-query", "domains": ["geosite:local"],
                         "queryStrategy": "UseIPv4"}],
            "queryStrategy": "UseIPv4"}


def rules(target, mobile):
    via = {"balancerTag": "balancer"} if target == "balancer" else {"outboundTag": "proxy"}
    block = [{"type": "field", "domain": ["geosite:ads"], "outboundTag": "block"},
             {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}]
    last = [{"type": "field", "network": "tcp,udp", **via}]
    if mobile:
        return block + [{"type": "field", "ip": ["geoip:private", "geoip:local"], "outboundTag": "direct"},
                        {"type": "field", "domain": ["geosite:private", "geosite:local"], "outboundTag": "direct"}] + last
    return block + [{"type": "field", "domain": ["geosite:streaming", "domain:video.example.com"], **via},
                    {"type": "field", "ip": ["geoip:private", "geoip:local"], "outboundTag": "direct"},
                    {"type": "field", "ip": ["9.9.9.9"], "outboundTag": "direct"},
                    {"type": "field", "domain": ["geosite:private", "geosite:local"], "outboundTag": "direct"}] + last


def config(remarks, description, kinds, balanced, index):
    mobile = kinds.startswith("g")
    cfg = {"dns": dns(mobile),
           "routing": {"rules": rules("balancer" if balanced else "proxy", mobile),
                       "domainMatcher": "hybrid", "domainStrategy": "IPIfNonMatch"},
           "inbounds": INBOUNDS,
           "outbounds": proxies(kinds if balanced else [kinds])
           + [{"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}],
           "remarks": remarks}
    if balanced:
        cfg["routing"]["balancers"] = [{"tag": "balancer", "selector": ["proxy"],
                                        "strategy": STRATEGIES[index % len(STRATEGIES)], "fallbackTag": "proxy"}]
        cfg["burstObservatory"] = {"subjectSelector": ["proxy"],
                                   "pingConfig": {"destination": "https://probe.example.com/generate_204",
                                                  "connectivity": "", "interval": "1m", "sampling": 2, "timeout": "3s"}}
    if description:
        cfg["meta"] = {"serverDescription": description}
    return cfg


def main():
    configs = [config(r, d, k, True, i) for i, (r, d, k) in enumerate(BALANCED)]
    configs += [config(r, d, k, False, i) for i, (r, d, k) in enumerate(SINGLE)]
    json.dump(configs, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
