# Turn one subscription profile config into the router's xray config.
#
# Only the entry points and service blocks change. outbounds, routing.rules,
# routing.balancers, routing.domainStrategy, dns and burstObservatory pass through
# unchanged (outbounds only gain streamSettings.sockopt.mark).
#
# Arguments:
#   --argjson tproxy_port N   --argjson dns_port N   --argjson mark N
#   --arg loglevel S          --arg error_log S

def sniffing_from_socks:
  ([.inbounds[]? | select(.protocol == "socks") | .sniffing] | first)
  // {enabled: true, routeOnly: false, destOverride: ["http", "tls", "quic"]};

# Merge sockopt.mark into an outbound, keeping any existing streamSettings/sockopt keys.
# Traffic marked this way bypasses the tproxy rules.
def with_mark:
  if .tag == "block" then .
  else .streamSettings = ((.streamSettings // {}) | .sockopt = ((.sockopt // {}) | .mark = $mark))
  end;

. as $in
| del(.remarks, .meta)
| .inbounds = [
    { tag: "tproxy", protocol: "dokodemo-door", listen: "0.0.0.0", port: $tproxy_port,
      settings: { network: "tcp,udp", followRedirect: true },
      streamSettings: { sockopt: { tproxy: "tproxy" } },
      sniffing: ($in | sniffing_from_socks) },
    { tag: "dns-in", protocol: "dokodemo-door", listen: "0.0.0.0", port: $dns_port,
      settings: { address: "1.1.1.1", port: 53, network: "tcp,udp" } },
    { tag: "api", protocol: "dokodemo-door", listen: "127.0.0.1", port: 10085,
      settings: { address: "127.0.0.1" } }
  ]
| .outbounds = ((.outbounds // []) | map(with_mark)) + [{ tag: "dns-out", protocol: "dns" }]
| .routing.rules = [
    { type: "field", inboundTag: ["dns-in"], outboundTag: "dns-out" },
    { type: "field", inboundTag: ["api"], outboundTag: "api" }
  ] + (.routing.rules // [])
| .log = (.log // {}) + { loglevel: $loglevel, access: "none", error: $error_log }
| .stats = (.stats // {})
| .api = (.api // {}) + { tag: "api", services: ["HandlerService", "StatsService", "RoutingService"] }
| .policy = (.policy // {})
| .policy.system = (.policy.system // {}) + { statsOutboundUplink: true, statsOutboundDownlink: true }
