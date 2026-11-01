# Turn one subscription profile config into the router's xray config.
#
# Only the entry points and service blocks change. outbounds, routing.rules,
# routing.balancers, routing.domainStrategy, dns and burstObservatory pass through
# unchanged (outbounds only gain streamSettings.sockopt.mark); the user's own rules go in
# among routing.rules (user_rules).
#
# Arguments:
#   --argjson tproxy_port N   --argjson dns_port N   --argjson mark N
#   --arg loglevel S          --argjson check_port N   --arg check_pass S
#   --argjson user_rules [{domain or ip, to: "proxy"|"direct"}]   (lib/rules.sh)

def sniffing_from_socks:
  ([.inbounds[]? | select(.protocol == "socks") | .sniffing] | first)
  // {enabled: true, routeOnly: false, destOverride: ["http", "tls", "quic"]};

# Merge sockopt.mark into an outbound, keeping any existing streamSettings/sockopt keys.
# Traffic marked this way bypasses the tproxy rules.
def with_mark:
  if .tag == "block" then .
  else .streamSettings = ((.streamSettings // {}) | .sockopt = ((.sockopt // {}) | .mark = $mark))
  end;

# The provider's catch-all: its last rule when that matches on nothing but the network.
def has_catch_all($rules):
  ($rules | length) > 0
  and (($rules[-1] | keys) - ["type", "network", "outboundTag", "balancerTag", "ruleTag"]) == [];

def protocol_of($cfg; $tag): [($cfg.outbounds // [])[] | select(.tag == $tag) | .protocol] | first;

# Where "proxy" goes: where the catch-all goes when that is a tunnel, else the first balancer,
# else the first outbound that is neither freedom, blackhole nor dns. null: nowhere.
def tunnel_target($cfg; $catch):
  if $catch != null and $catch.balancerTag then {balancerTag: $catch.balancerTag}
  elif $catch != null and $catch.outboundTag
    and ((protocol_of($cfg; $catch.outboundTag) // "") | IN("freedom", "blackhole") | not)
  then {outboundTag: $catch.outboundTag}
  elif (($cfg.routing.balancers // []) | length) > 0 then {balancerTag: $cfg.routing.balancers[0].tag}
  else [($cfg.outbounds // [])[] | select(.protocol | IN("freedom", "blackhole", "dns") | not) | {outboundTag: .tag}] | first
  end;

# The user's rules as xray rules: domains, more specific first, then addresses, IPv4 before IPv6,
# narrower subnets first (a single address is /32 or /128), an equal mask in the order of the
# settings: a domain rule wins over an address rule for the same connection. The provider's rules take
# priority: these go after its explicit ones and before its catch-all, and only take traffic
# from the LAN and the services check (a TestRoute from another inbound tag sees the provider's
# rules alone: lib/route.sh). "direct" goes to the first freedom outbound; a rule with nowhere to
# go is left out. Without a catch-all under IPIfNonMatch, a domain rule at the end would match on
# xray's first, domain-only pass, ahead of the provider's address rules that only match on the
# second one: an address condition that takes any address keeps it out of the first pass.
def user_rules($cfg):
  ($cfg.routing.rules // []) as $rules
  | has_catch_all($rules) as $catch
  | tunnel_target($cfg; if $catch then $rules[-1] else null end) as $proxy
  | ([($cfg.outbounds // [])[] | select(.protocol == "freedom") | {outboundTag: .tag}] | first) as $direct
  | (($catch | not) and (($cfg.routing.domainStrategy // "") | ascii_downcase) == "ipifnonmatch") as $second
  | ([$user_rules[] | select(has("domain"))] | sort_by(-(.domain | split(".") | length)))
    + ([$user_rules[] | select(has("ip"))]
       | sort_by(.ip | contains(":") as $v6
           | [$v6, -(if contains("/") then split("/")[1] | tonumber elif $v6 then 128 else 32 end)]))
  | map((if .to == "proxy" then $proxy else $direct end) as $target
      | select($target != null)
      | if has("ip") then { type: "field", inboundTag: ["tproxy", "check"], ip: [.ip] }
        else { type: "field", inboundTag: ["tproxy", "check"], domain: ["domain:" + .domain] }
          + (if $second then { ip: ["0.0.0.0/0", "::/0"] } else {} end)
        end
        + $target)
  # xray wants every rule tag unique; the tag names the rule in its log ("Hit route rule")
  | to_entries | map(.value + { ruleTag: "gatygo-rule-\(.key + 1)" });

. as $in
| del(.remarks, .meta)
| .inbounds = [
    # 127.0.0.1: the nft rule delivers the LAN's packets here (firewall.sh); dns-in takes
    # redirected packets, whose destination is the router's LAN address
    { tag: "tproxy", protocol: "dokodemo-door", listen: "127.0.0.1", port: $tproxy_port,
      settings: { network: "tcp,udp", followRedirect: true },
      streamSettings: { sockopt: { tproxy: "tproxy" } },
      sniffing: ($in | sniffing_from_socks) },
    { tag: "dns-in", protocol: "dokodemo-door", listen: "0.0.0.0", port: $dns_port,
      settings: { address: "1.1.1.1", port: 53, network: "tcp,udp" } },
    { tag: "api", protocol: "dokodemo-door", listen: "127.0.0.1", port: 10085,
      settings: { address: "127.0.0.1" } },
    # The router's own traffic bypasses the tproxy rules, so `gatygo check` enters here:
    # local only, routed by the same rules as the LAN. The password keeps every other process
    # on the router out of the tunnel.
    { tag: "check", protocol: "socks", listen: "127.0.0.1", port: $check_port,
      settings: { auth: "password", accounts: [{ user: "gatygo", pass: $check_pass }], udp: false } }
  ]
| .outbounds = ((.outbounds // []) | map(with_mark)) + [{ tag: "dns-out", protocol: "dns" }]
| .routing.rules = [
    { type: "field", inboundTag: ["dns-in"], outboundTag: "dns-out" },
    { type: "field", inboundTag: ["api"], outboundTag: "api" }
  ] + ((.routing.rules // []) as $rules | user_rules($in) as $mine
      | if ($mine | length) == 0 then $rules
        elif has_catch_all($rules) then $rules[:-1] + $mine + [$rules[-1]]
        else $rules + $mine
        end)
# error "" = console; procd relays it to the system log (bounded ring buffer, `logread -e xray`)
| .log = (.log // {}) + { loglevel: $loglevel, access: "none", error: "" }
| .stats = (.stats // {})
# no HandlerService: it hands the outbounds (server addresses and keys) to any local process
| .api = (.api // {}) + { tag: "api", services: ["StatsService", "RoutingService"] }
| .policy = (.policy // {})
| .policy.system = (.policy.system // {}) + { statsOutboundUplink: true, statsOutboundDownlink: true }
