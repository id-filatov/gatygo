#!/bin/sh
# Transparent proxy rules: own nftables table `inet gatygo` (fw4's table is never
# touched) and the policy route that delivers tproxy-marked packets locally. Everything applied
# by gatygo_fw_apply is removed by gatygo_fw_remove.
#
# `redirect` is only valid in a nat chain, so the DNS hijack lives in its own nat-hook chain and
# port 53 is excluded from the tproxy chain.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"

gatygo_nft_ruleset() {
    _gatygo_ifs=$(printf '%s' "$GATYGO_LAN_IFACES" | tr -s ' ' | sed 's/ /, /g')
    cat <<RULES
table inet gatygo
delete table inet gatygo
table inet gatygo {
	set lan_ifaces {
		type ifname
		elements = { $_gatygo_ifs }
	}
	set reserved4 {
		type ipv4_addr
		flags interval
		elements = { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }
	}
	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;
		iifname != @lan_ifaces return
		meta mark $GATYGO_MARK return
		fib daddr type local return
		ip daddr @reserved4 return
		meta l4proto { tcp, udp } th dport 53 return
		meta l4proto { tcp, udp } tproxy ip to :$GATYGO_TPROXY_PORT meta mark set 0x1 counter accept
	}
	chain dns_redirect {
		type nat hook prerouting priority dstnat - 1; policy accept;
		iifname != @lan_ifaces return
		fib daddr type local return
		ip daddr @reserved4 return
		meta l4proto { tcp, udp } th dport 53 counter redirect to :$GATYGO_DNS_PORT
	}
RULES
    if [ "$GATYGO_IPV6_BLOCK" = 1 ]; then
        cat <<RULES
	chain forward6 {
		type filter hook forward priority filter - 1; policy accept;
		iifname @lan_ifaces ip6 daddr != { fe80::/10, fc00::/7 } counter drop
	}
RULES
    fi
    echo "}"
}

# gatygo_fw_apply — load the ruleset (replacing any previous one) and the policy route
gatygo_fw_apply() {
    gatygo_nft_ruleset | nft -f - || { gatygo_log error "firewall: nft refused the ruleset"; return 1; }
    ip rule del fwmark 0x1 lookup 100 2>/dev/null
    ip rule add fwmark 0x1 lookup 100
    ip route replace local default dev lo table 100
}

# gatygo_fw_remove — undo gatygo_fw_apply; safe to call when nothing is applied
gatygo_fw_remove() {
    nft delete table inet gatygo 2>/dev/null
    ip rule del fwmark 0x1 lookup 100 2>/dev/null
    ip route flush table 100 2>/dev/null
    return 0
}
