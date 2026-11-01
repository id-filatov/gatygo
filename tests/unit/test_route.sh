#!/bin/sh
# Where a domain goes, as the running xray answers it (RoutingService.TestRoute over h2c): a real
# xray with the router's config, minus the inbounds only the router can open (tproxy needs
# CAP_NET_ADMIN). The rules' inbound tags still count: TestRoute names the inbound itself.
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state" GATYGO_RUN="$tmp/run" NSLOOKUP_STUB_FILE="$tmp/hosts"
mkdir -p "$GATYGO_STATE" "$GATYGO_RUN"; : > "$NSLOOKUP_STUB_FILE"
. "$GATYGO_LIB/config.sh"
. "$GATYGO_LIB/transform.sh"
. "$GATYGO_LIB/route.sh"
CLI=/src/gatygo/files/gatygo
jq '.[0]' "$FIXTURES/subscription.json" > "$tmp/p0.json"
# the fixture's lists (tools/gen-geodat.py): ads.example.com is an ad, example.org local (direct),
# video.example.com streaming (balancer); anything else takes the catch-all (balancer)
UR='[{"domain":"rare.example","to":"direct"},{"domain":"other.example","to":"proxy"},{"domain":"example.org","to":"proxy"},{"domain":"video.example.com","to":"direct"},{"domain":"ads.example.com","to":"direct"}]'

# _conf IN OUT RULES [FILTER] — the router's config for IN with RULES, then FILTER; OUT.run.json is what runs here
_conf() {
    gatygo_transform "$1" "$2.tmp" 12345 5353 255 none 10808 s3cret "$3" && jq "${4:-.}" "$2.tmp" > "$2" && rm -f "$2.tmp"
    jq '.inbounds |= map(select(.tag == "api"))' "$2" > "$2.run.json"
}
_up() {
    /usr/local/bin/xray run -c "$1.run.json" > "$tmp/xray.log" 2>&1 &
    _xray=$!
    for _ in $(seq 1 50); do nc -z 127.0.0.1 10085 2>/dev/null && return 0; sleep 0.1; done
    return 1
}
_down() { kill "$_xray" 2>/dev/null; wait "$_xray" 2>/dev/null; }
_st() { gatygo_rules_status "$1" "$2" | jq -r '[.[].status | tostring] | join(" ")'; }

# --- the provider has a catch-all: each kind of status
_conf "$tmp/p0.json" "$tmp/c0.json" "$UR"
assert_exit 0 "xray answers on the API port" _up "$tmp/c0.json"
assert_eq "direct" "$(gatygo_route_ask tproxy rare.example)" "the outbound tag xray picks"
assert_eq "works nochange provider_direct provider_proxy provider_block" "$(_st "$tmp/c0.json" "$UR")" \
    "statuses: works, changes nothing, beaten by the provider's direct, tunnel and block"
assert_eq '{"domain":"rare.example","to":"direct","status":"works"}' "$(gatygo_rules_status "$tmp/c0.json" "$UR" | jq -c '.[0]')" "a status line keeps the rule"
assert_eq "block" "$(gatygo_route_to "$tmp/c0.json" tproxy ads.example.com)" "route: a domain the provider blocks"
assert_eq "direct" "$(gatygo_route_to "$tmp/c0.json" tproxy rare.example)" "route: the user's direct rule"
assert_eq "proxy" "$(gatygo_route_to "$tmp/c0.json" gatygo-probe rare.example)" "route: the provider's alone from another inbound"
( GATYGO_API=127.0.0.1:1; gatygo_route_ask tproxy rare.example ); assert_eq "1" "$?" "no API: the call fails"
assert_eq "null null null null null" "$(GATYGO_API=127.0.0.1:1 _st "$tmp/c0.json" "$UR")" "no API: no statuses"
( gatygo_route_ask tproxy rare.example 999.1.1.1 ); assert_eq "1" "$?" "a bad address is not sent"
# the cost does not grow with the rules: one curl for all the calls, a fixed handful of jq
mkdir -p "$tmp/count"
for c in curl jq; do
    printf '#!/bin/sh\necho x >> %s/%s.n\nexec %s "$@"\n' "$tmp/count" "$c" "$(command -v "$c")" > "$tmp/count/$c"
    chmod +x "$tmp/count/$c"
done
( PATH="$tmp/count:$PATH"; gatygo_rules_status "$tmp/c0.json" "$UR" > "$tmp/count/out" )
assert_eq "works nochange provider_direct provider_proxy provider_block" "$(jq -r '[.[].status] | join(" ")' "$tmp/count/out")" "the same statuses, counted"
assert_eq "1" "$(wc -l < "$tmp/count/curl.n" | tr -d ' ')" "one curl for five rules"
assert_exit 0 "at most three jq for five rules" test "$(wc -l < "$tmp/count/jq.n")" -le 3
# address rules too: their statuses known without asking add no call, the others join the same curl
UM=$(printf '%s' "$UR" | jq -c '. + [{"ip":"203.0.113.0/24","to":"direct"},{"ip":"198.51.100.7","to":"proxy"},{"ip":"10.8.0.0/24","to":"proxy"},{"ip":"2001:db8::/32","to":"proxy"},{"ip":"0.0.0.0/0","to":"direct"}]')
rm -f "$tmp/count/curl.n" "$tmp/count/jq.n"
( PATH="$tmp/count:$PATH"; gatygo_rules_status "$tmp/c0.json" "$UM" > "$tmp/count/out" )
assert_eq "10" "$(jq '[.[].status | select(. != null)] | length' "$tmp/count/out")" "a status for each of ten rules, five of them addresses"
assert_eq "1" "$(wc -l < "$tmp/count/curl.n" | tr -d ' ')" "one curl for ten rules, five of them addresses"
assert_exit 0 "at most three jq for ten rules" test "$(wc -l < "$tmp/count/jq.n")" -le 3
_down

# --- the provider's inbound does not sniff (or not TLS): the LAN's connections carry no domain,
#     no domain rule takes them, and the status says what their address gets
UR4='[{"domain":"rare.example","to":"direct"},{"domain":"other.example","to":"proxy"}]'
printf 'rare.example 1.2.3.4\nother.example 1.2.3.5\n' > "$NSLOOKUP_STUB_FILE"
_conf "$tmp/p0.json" "$tmp/ns.json" "$UR4" '.inbounds[0].sniffing.enabled = false'
_up "$tmp/ns.json"
assert_eq "provider_proxy nochange" "$(_st "$tmp/ns.json" "$UR4")" "no sniffing: no rule can work"
assert_eq "proxy" "$(gatygo_route_where "$tmp/ns.json" rare.example)" "the site check asks as the LAN's connection would: by address"
assert_eq "direct" "$(gatygo_route_where "$tmp/c0.json" rare.example)" "with sniffing, by domain"
_down
_conf "$tmp/p0.json" "$tmp/nt.json" "$UR4" '.inbounds[0].sniffing.destOverride = ["http"]'
_up "$tmp/nt.json"
assert_eq "provider_proxy nochange" "$(_st "$tmp/nt.json" "$UR4")" "no TLS sniffing: HTTPS sites carry no domain"
_down
: > "$NSLOOKUP_STUB_FILE"

# --- no catch-all under IPIfNonMatch: the provider's address rule still wins over a user's domain
jq 'del(.routing.rules[-1]) | .dns.hosts += {"rare.example": "9.9.9.9", "far.example": "1.2.3.4"}' "$tmp/p0.json" > "$tmp/nc-in.json"
UR2='[{"domain":"rare.example","to":"proxy"},{"domain":"far.example","to":"direct"}]'
_conf "$tmp/nc-in.json" "$tmp/nc.json" "$UR2"
_up "$tmp/nc.json"
assert_eq "provider_direct works" "$(_st "$tmp/nc.json" "$UR2")" \
    "9.9.9.9 is the provider's direct address; far.example has no provider rule (no route = the first outbound)"
_down

# --- no route at all: the traffic takes the first outbound, and so does the answer
jq 'del(.routing.rules[-1]) | .routing.domainStrategy = "AsIs"' "$tmp/p0.json" > "$tmp/na-in.json"
_conf "$tmp/na-in.json" "$tmp/na.json" "$UR"
_up "$tmp/na.json"
( gatygo_route_ask gatygo-probe nowhere.example ); assert_eq "3" "$?" "xray finds no route"
assert_eq "proxy" "$(gatygo_route_to "$tmp/na.json" gatygo-probe nowhere.example)" "the first outbound's direction"
_down

# --- a balancer without a fallback, before any measurement
_conf "$tmp/p0.json" "$tmp/nf.json" "$UR" 'del(.routing.balancers[0].fallbackTag)'
_up "$tmp/nf.json"
assert_eq "proxy" "$(gatygo_route_to "$tmp/nf.json" tproxy other.example)" "a balancer that picks nothing still means the tunnel"
_down

# --- routeOnly: the traffic keeps its address, and the provider's address rules see it first
UR3='[{"domain":"rare.example","to":"proxy"}]'
_conf "$tmp/p0.json" "$tmp/ro.json" "$UR3" '.inbounds[0].sniffing.routeOnly = true'
echo "rare.example 9.9.9.9" > "$NSLOOKUP_STUB_FILE"
assert_eq "9.9.9.9" "$(gatygo_route_ips rare.example)" "addresses from the router's DNS"
assert_eq "" "$(gatygo_route_ips nowhere.example)" "none for a name it cannot resolve"
_up "$tmp/ro.json"
assert_eq "direct" "$(gatygo_route_to "$tmp/ro.json" tproxy rare.example 9.9.9.9)" "with its address the provider's rule wins"
assert_eq "proxy" "$(gatygo_route_to "$tmp/ro.json" tproxy rare.example)" "without it the user's rule would"
assert_eq "provider_direct" "$(_st "$tmp/ro.json" "$UR3")" "so the status asks with the address"
assert_eq "provider_proxy" "$(_st "$tmp/c0.json" '[{"domain":"video.example.com","to":"direct"}]')" "no routeOnly: the domain alone (and no DNS asked)"
_down
: > "$NSLOOKUP_STUB_FILE"

# --- address rules: a status by one address of the rule (no domain), IPv6 and the local network
#     told apart without asking. The fixture's geoip:local is the documentation ranges, sent direct
#     by the provider ahead of any user rule: these configs leave it out of the provider's rule.
NOLOCAL='.routing.rules |= map(if .ip == ["geoip:private","geoip:local"] then .ip = ["geoip:private"] else . end)'
URI='[{"ip":"203.0.113.0/24","to":"direct"},{"ip":"198.51.100.7","to":"proxy"},{"ip":"9.9.9.9","to":"proxy"},{"ip":"10.8.0.0/24","to":"proxy"},{"ip":"10.8.0.0/24","to":"direct"},{"ip":"2001:db8::/32","to":"proxy"},{"ip":"2001:db8::1","to":"direct"}]'
# (two rules on 10.8.0.0/24: for the statuses only, gatygo_rules_json would skip the second)
_conf "$tmp/p0.json" "$tmp/ci.json" "$URI" "$NOLOCAL"; _up "$tmp/ci.json"
assert_eq "works nochange provider_direct local nochange ipv6_blocked ipv6_blocked" "$(GATYGO_IPV6_BLOCK=1 _st "$tmp/ci.json" "$URI")" "address statuses, IPv6 blocked"
assert_eq "ipv6_bypass nochange" "$(GATYGO_IPV6_BLOCK=0 _st "$tmp/ci.json" "$URI" | cut -d' ' -f6-)" "IPv6 not blocked: tunnel goes around, direct changes nothing"
assert_eq '{"ip":"203.0.113.0/24","to":"direct","status":"works"}' "$(gatygo_rules_status "$tmp/ci.json" "$URI" | jq -c '.[0]')" "a status line keeps an address rule"
assert_eq "local nochange" "$(GATYGO_IPV6_BLOCK=1 _st "$tmp/ci.json" '[{"ip":"fd00::/8","to":"proxy"},{"ip":"fe80::1","to":"direct"}]')" \
    "a local IPv6 network is not blocked with IPv6: always direct"
_down
_conf "$tmp/p0.json" "$tmp/cl.json" '[{"ip":"203.0.113.0/24","to":"proxy"}]'; _up "$tmp/cl.json"
assert_eq "provider_direct" "$(_st "$tmp/cl.json" '[{"ip":"203.0.113.0/24","to":"proxy"}]')" "the provider's geoip rule beats the user's address rule"
_down
U2='[{"ip":"203.0.113.0/25","to":"proxy"},{"ip":"203.0.113.128/25","to":"proxy"},{"ip":"203.0.113.0/24","to":"direct"},{"ip":"0.0.0.0/0","to":"direct"}]'
_conf "$tmp/p0.json" "$tmp/c2.json" "$U2" "$NOLOCAL"; _up "$tmp/c2.json"
# 0.0.0.0/0 direct is checked at 1.0.0.0 (not 0.0.0.0, a local one), outside the narrower rules
assert_eq "nochange nochange nochange works" "$(_st "$tmp/c2.json" "$U2")" "a subnet covered by narrower rules changes nothing; 0.0.0.0/0 checked outside the local ones"
_down

# --- one connection with a domain and an address (routeOnly: xray sees both): the domain rule decides
UD='[{"domain":"rare.example","to":"direct"},{"ip":"203.0.113.0/24","to":"proxy"}]'
echo "rare.example 203.0.113.10" > "$NSLOOKUP_STUB_FILE"
_conf "$tmp/p0.json" "$tmp/rd.json" "$UD" ".inbounds[0].sniffing.routeOnly = true | $NOLOCAL"; _up "$tmp/rd.json"
assert_eq "direct" "$(gatygo_route_to "$tmp/rd.json" tproxy rare.example 203.0.113.10)" "domain wins over an address rule"
assert_eq "works nochange" "$(_st "$tmp/rd.json" "$UD")" "and its status says it works"
_down

# --- no TLS sniffing: a domain rule is asked by its address, which the user's address rule may take;
#     the status blames the provider only when its rules alone send the address there
UA='[{"domain":"rare.example","to":"proxy"},{"ip":"203.0.113.0/24","to":"direct"}]'
_conf "$tmp/p0.json" "$tmp/ad.json" "$UA" ".inbounds[0].sniffing.destOverride = [\"http\"] | $NOLOCAL"; _up "$tmp/ad.json"
assert_eq "nochange works" "$(_st "$tmp/ad.json" "$UA")" "decided by the user's address rule, not the provider: nochange"
_down
UA2='[{"domain":"rare.example","to":"direct"},{"ip":"203.0.113.0/24","to":"proxy"}]'
_conf "$tmp/p0.json" "$tmp/ad2.json" "$UA2" ".inbounds[0].sniffing.destOverride = [\"http\"] | $NOLOCAL"; _up "$tmp/ad2.json"
assert_eq "provider_proxy nochange" "$(_st "$tmp/ad2.json" "$UA2")" "the provider's rules alone would send the address to the tunnel too: provider_proxy"
_down
: > "$NSLOOKUP_STUB_FILE"

# --- the commands
assert_eq '{"error":"not a domain or an address"}' "$(sh "$CLI" route bad..domain)" "route: not a domain"
assert_exit 1 "route: not a domain fails" sh "$CLI" route bad..domain
cp "$tmp/c0.json" "$GATYGO_STATE/xray.json"; echo "🌐 Auto" > "$GATYGO_STATE/profile"
printf '%s' "$UR" | jq -r 'to_entries[] | "\(.key) \(.value.domain) \(.value.to)"' | while read -r i d to; do
    uci set "gatygo.@rule[$i]=rule"; uci set "gatygo.@rule[$i].domain=$d"; uci set "gatygo.@rule[$i].to=$to"
done
printf '%s\n' "$UR" > "$GATYGO_STATE/rules.json"
assert_eq '{"available":false,"to":null,"why":null}' "$(sh "$CLI" route rare.example)" "route: no VPN"
assert_eq "false false null" "$(sh "$CLI" rules | jq -r '"\(.available) \(.pending) \(.rules[0].status)"')" "rules: no VPN, no statuses"
export UBUS_STUB_RUNNING=1
_up "$tmp/c0.json"
assert_eq '{"available":true,"to":"direct","why":null}' "$(sh "$CLI" route rare.example)" "route: the answer"
assert_eq '{"available":true,"api":true,"pending":false,"profile":"🌐 Auto"}' "$(sh "$CLI" rules | jq -c 'del(.rules)')" "rules: VPN on, all applied"
assert_eq "works nochange provider_direct provider_proxy provider_block" "$(sh "$CLI" rules | jq -r '[.rules[].status] | join(" ")')" "rules: every status"
uci set 'gatygo.@rule[0].to=proxy'
assert_eq "true null" "$(sh "$CLI" rules | jq -r '"\(.pending) \(.rules[0].status)"')" "a saved change the config does not have yet: pending"
uci set 'gatygo.@rule[0].to=direct'
mkdir -p "$GATYGO_RUN/update.lock"; sleep 30 & _upd=$!; echo "$_upd" > "$GATYGO_RUN/update.lock/pid"
assert_eq "true" "$(sh "$CLI" rules | jq -r .pending)" "an update running: pending"
kill "$_upd" 2>/dev/null; wait "$_upd" 2>/dev/null; rm -rf "$GATYGO_RUN/update.lock"
_down
assert_eq '{"available":true,"to":null,"why":null}' "$(sh "$CLI" route rare.example)" "route: the API does not answer"
: > "$SYSLOG_STUB_FILE"
assert_eq "false null" "$(sh "$CLI" rules | jq -r '"\(.api) \(.rules[0].status)"')" "rules: the API does not answer"
sh "$CLI" rules >/dev/null; sh "$CLI" rules >/dev/null
assert_eq "1" "$(grep -c '\[warn\] the xray API does not answer' "$SYSLOG_STUB_FILE")" "the API down is logged, once"
_up "$tmp/c0.json"; sh "$CLI" rules >/dev/null; _down; : > "$SYSLOG_STUB_FILE"; sh "$CLI" rules >/dev/null
assert_eq "1" "$(grep -c '\[warn\] the xray API does not answer' "$SYSLOG_STUB_FILE")" "and again after it came back and went"
# no catch-all under IPIfNonMatch and a DNS server that never answers (xray gives up after 4 s):
# the API check must not wait on it
jq 'del(.routing.rules[-1]) | .dns = {servers: ["udp+local://10.255.255.1:53"]}' "$tmp/p0.json" > "$tmp/sd-in.json"
_conf "$tmp/sd-in.json" "$tmp/sd.json" '[]'
cp "$tmp/sd.json" "$GATYGO_STATE/xray.json"; cp "$UCI_STUB_FILE" "$tmp/uci.keep"; : > "$UCI_STUB_FILE"; echo '[]' > "$GATYGO_STATE/rules.json"
_up "$tmp/sd.json"
_t0=$(date +%s); _api=$(sh "$CLI" rules | jq -r .api); _t1=$(date +%s)
assert_eq "true fast" "$_api $([ $((_t1 - _t0)) -le 2 ] && echo fast || echo "slow: $((_t1 - _t0)) s")" "the API check does not wait on DNS"
_down
cp "$tmp/uci.keep" "$UCI_STUB_FILE"; printf '%s\n' "$UR" > "$GATYGO_STATE/rules.json"
jq '.inbounds |= map(select(.tag != "api"))' "$tmp/c0.json" > "$GATYGO_STATE/xray.json"
assert_eq '{"available":true,"to":null,"why":null}' "$(sh "$CLI" route rare.example)" "route: a config without the API: xray runs, cannot tell"
assert_eq "true false" "$(sh "$CLI" rules | jq -r '"\(.available) \(.api)"')" "rules: a config without the API: xray runs, cannot tell"

# --- the site check takes an address or a subnet
cp "$tmp/ci.json" "$GATYGO_STATE/xray.json"; _up "$tmp/ci.json"
assert_eq '{"available":true,"to":"direct","why":null}' "$(sh "$CLI" route 203.0.113.5)" "route: an address, by the user's rule"
assert_eq '{"available":true,"to":"block","why":"ipv6_blocked"}' "$(sh "$CLI" route 2001:db8::5)" "route: IPv6 is blocked by default"
uci set gatygo.main.ipv6_block=0
assert_eq '{"available":true,"to":"direct","why":"ipv6_bypass"}' "$(sh "$CLI" route 2001:DB8::5)" "route: IPv6 not blocked goes around the VPN"
uci delete gatygo.main.ipv6_block
assert_eq '{"available":true,"to":"direct","why":"local"}' "$(sh "$CLI" route 10.8.0.5)" "route: the local network"
# a subnet is asked at the address its status would be: outside the user's narrower rules that xray
# runs with (a rule saved but not applied yet is not one of them)
uci set 'gatygo.@rule[5]=rule'; uci set 'gatygo.@rule[5].ip=203.0.112.0/24'; uci set 'gatygo.@rule[5].to=direct'
assert_eq '{"available":true,"to":"proxy","why":null}' "$(sh "$CLI" route 203.0.112.0/23)" "route: a narrower rule saved, not applied yet, does not count"
printf '%s\n' '[{"domain":"rare.example","to":"direct"},{"ip":"203.0.112.0/24","to":"direct"}]' > "$GATYGO_STATE/rules.json"
assert_eq '{"available":true,"to":"direct","why":null}' "$(sh "$CLI" route 203.0.112.0/23)" "route: a subnet, outside a narrower applied rule (203.0.113.0)"
assert_eq '{"available":true,"to":"proxy","why":null}' "$(sh "$CLI" route 203.0.112.0/24)" "route: a subnet, at its first address"
assert_eq '{"error":"not a domain or an address"}' "$(sh "$CLI" route not..valid)" "route: neither a domain nor an address"
assert_exit 1 "route: neither fails" sh "$CLI" route not..valid
_down
unset UBUS_STUB_RUNNING

rm -rf "$tmp"
report
