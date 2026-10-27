#!/bin/sh
. "$(dirname "$0")/../lib.sh"
. "$GATYGO_LIB/transform.sh"
tmp=$(mktemp -d)
FIX="$FIXTURES/subscription.json"

# jq: outbounds of the router config projected back to the subscription's shape
_STRIP_MARK='.outbounds[:-1] | map(del(.streamSettings.sockopt.mark) | if .streamSettings.sockopt == {} then del(.streamSettings.sockopt) else . end | if .streamSettings == {} then del(.streamSettings) else . end)'

i=0
while [ "$i" -lt 13 ]; do
    in="$tmp/in-$i.json"; out="$tmp/out-$i.json"
    jq ".[$i]" "$FIX" > "$in"
    name=$(jq -r .remarks "$in")

    gatygo_transform "$in" "$out" 12345 5353 255 warning 10808 s3cret
    assert_eq "0" "$?" "transform succeeds: $name"
    assert_exit 0 "xray run -test accepts the result: $name" xray run -test -c "$out"

    # inbounds are replaced
    assert_eq '["tproxy","dns-in","api","check"]' "$(jq -c '[.inbounds[].tag]' "$out")" "inbounds replaced: $name"
    # local only: the nft rule hands the LAN's packets to it, nothing can connect to it directly
    assert_exit 0 "tproxy inbound shape: $name" jq -e \
        '.inbounds[0] | .protocol == "dokodemo-door" and .listen == "127.0.0.1" and .port == 12345
            and .settings.network == "tcp,udp" and .settings.followRedirect == true
            and .streamSettings.sockopt.tproxy == "tproxy"' "$out"
    assert_eq "$(jq -c '.inbounds[] | select(.protocol == "socks") | .sniffing' "$in")" \
        "$(jq -c '.inbounds[0].sniffing' "$out")" "tproxy sniffing copied from the socks inbound: $name"
    assert_exit 0 "dns-in inbound shape: $name" jq -e \
        '.inbounds[1] | .protocol == "dokodemo-door" and .listen == "0.0.0.0" and .port == 5353
            and .settings.address == "1.1.1.1" and .settings.port == 53 and .settings.network == "tcp,udp"' "$out"
    assert_exit 0 "api inbound shape: $name" jq -e \
        '.inbounds[2] | .protocol == "dokodemo-door" and .listen == "127.0.0.1" and .port == 10085
            and .settings.address == "127.0.0.1"' "$out"
    # the router's own traffic bypasses the tunnel: `gatygo check` goes in through this one
    # and only with the router's own password: nothing else on the router gets a way into the tunnel
    assert_exit 0 "check inbound is a local-only socks behind a password: $name" jq -e \
        '.inbounds[3] | .protocol == "socks" and .listen == "127.0.0.1" and .port == 10808
            and .settings.udp == false and .settings.auth == "password"
            and .settings.accounts == [{"user": "gatygo", "pass": "s3cret"}]' "$out"

    # outbounds: untouched except sockopt.mark, plus dns-out at the end
    assert_exit 0 "outbounds minus mark equal the original: $name" jq -e --slurpfile o "$in" \
        "($_STRIP_MARK) == \$o[0].outbounds" "$out"
    assert_exit 0 "dns-out appended last: $name" jq -e \
        '.outbounds[-1] == {"tag": "dns-out", "protocol": "dns"}' "$out"
    assert_exit 0 "every proxy/direct outbound carries the mark: $name" jq -e \
        '[.outbounds[] | select(.tag != "block" and .tag != "dns-out") | .streamSettings.sockopt.mark] | length > 0 and all(. == 255)' "$out"
    assert_exit 0 "block outbound has no streamSettings: $name" jq -e \
        '[.outbounds[] | select(.tag == "block")] | all(has("streamSettings") | not)' "$out"

    # routing: two rules prepended, everything else byte-for-byte
    assert_exit 0 "prepended routing rules: $name" jq -e \
        '.routing.rules[0] == {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "dns-out"}
         and .routing.rules[1] == {"type": "field", "inboundTag": ["api"], "outboundTag": "api"}' "$out"
    assert_exit 0 "original rules follow unchanged: $name" jq -e --slurpfile o "$in" \
        '.routing.rules[2:] == $o[0].routing.rules' "$out"
    assert_exit 0 "balancers, domainStrategy, dns, observatory unchanged: $name" jq -e --slurpfile o "$in" \
        '.routing.balancers == $o[0].routing.balancers and .routing.domainStrategy == $o[0].routing.domainStrategy
         and .dns == $o[0].dns and .burstObservatory == $o[0].burstObservatory' "$out"

    # service blocks
    assert_exit 0 "remarks and meta removed: $name" jq -e '(has("remarks") or has("meta")) | not' "$out"
    assert_exit 0 "log/stats/api/policy added: $name" jq -e \
        '.log == {"loglevel": "warning", "access": "none", "error": ""}
         and .stats == {}
         and .api == {"tag": "api", "services": ["StatsService", "RoutingService"]}
         and .policy == {"system": {"statsOutboundUplink": true, "statsOutboundDownlink": true}}' "$out"

    i=$((i + 1))
done

# --- deterministic: the same input always yields the same bytes
gatygo_transform "$tmp/in-0.json" "$tmp/again.json" 12345 5353 255 warning 10808 s3cret
assert_eq "$(sha256sum < "$tmp/out-0.json")" "$(sha256sum < "$tmp/again.json")" "transform is deterministic"

# --- existing service blocks are merged, not clobbered
jq '.api = {"tag": "api", "services": ["HandlerService"], "listen": "127.0.0.1:1"}
    | .log = {"access": "/tmp/access.log", "error": "/tmp/panel.log", "dnsLog": true}
    | .policy = {"levels": {"0": {"handshake": 4}}}
    | .stats = {"x": 1}' "$tmp/in-12.json" > "$tmp/merge-in.json"
gatygo_transform "$tmp/merge-in.json" "$tmp/merge-out.json" 12345 5353 255 debug 10808 s3cret
# HandlerService would let any local process read the outbounds (server addresses and keys)
assert_exit 0 "api merged (ours wins: the panel's HandlerService is dropped, extra keys kept)" jq -e \
    '.api.listen == "127.0.0.1:1" and .api.services == ["StatsService", "RoutingService"]' "$tmp/merge-out.json"
assert_exit 0 "log merged (access forced to none, error to console, dnsLog kept)" jq -e \
    '.log == {"access": "none", "dnsLog": true, "loglevel": "debug", "error": ""}' "$tmp/merge-out.json"
assert_exit 0 "policy merged (levels kept, system added)" jq -e \
    '.policy.levels["0"].handshake == 4 and .policy.system.statsOutboundDownlink == true' "$tmp/merge-out.json"
assert_exit 0 "stats kept" jq -e '.stats == {"x": 1}' "$tmp/merge-out.json"

# --- no socks inbound in the subscription -> default sniffing
jq '.inbounds = []' "$tmp/in-12.json" > "$tmp/nosocks-in.json"
gatygo_transform "$tmp/nosocks-in.json" "$tmp/nosocks-out.json" 12345 5353 255 warning 10808 s3cret
assert_eq '{"enabled":true,"routeOnly":false,"destOverride":["http","tls","quic"]}' \
    "$(jq -c '.inbounds[0].sniffing' "$tmp/nosocks-out.json")" "default sniffing when no socks inbound"

# --- outbound without streamSettings gets sockopt.mark; existing sockopt keys survive
jq '.outbounds = [{"tag": "proxy", "protocol": "freedom", "streamSettings": {"sockopt": {"tcpFastOpen": true}}},
                  {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}]' \
    "$tmp/in-12.json" > "$tmp/sockopt-in.json"
gatygo_transform "$tmp/sockopt-in.json" "$tmp/sockopt-out.json" 12345 5353 255 warning 10808 s3cret
assert_eq '{"tcpFastOpen":true,"mark":255}' "$(jq -c '.outbounds[0].streamSettings.sockopt' "$tmp/sockopt-out.json")" "existing sockopt keys kept"
assert_eq '{"sockopt":{"mark":255}}' "$(jq -c '.outbounds[1].streamSettings' "$tmp/sockopt-out.json")" "streamSettings created for direct"

# --- bad arguments: exit 1, OUT untouched
assert_exit 1 "non-numeric port is rejected" gatygo_transform "$tmp/in-0.json" "$tmp/bad.json" abc 5353 255 warning 10808 s3cret
assert_exit 1 "hex mark is rejected (caller converts)" gatygo_transform "$tmp/in-0.json" "$tmp/bad.json" 12345 5353 0xff warning 10808 s3cret
assert_exit 1 "empty port is rejected" gatygo_transform "$tmp/in-0.json" "$tmp/bad.json" "" 5353 255 warning 10808 s3cret
assert_exit 1 "a missing check port is rejected" gatygo_transform "$tmp/in-0.json" "$tmp/bad.json" 12345 5353 255 warning
assert_exit 1 "a missing check password is rejected" gatygo_transform "$tmp/in-0.json" "$tmp/bad.json" 12345 5353 255 warning 10808
assert_exit 1 "OUT is not created on bad arguments" test -e "$tmp/bad.json"
printf 'not json' > "$tmp/notjson.json"
assert_exit 1 "invalid JSON input is rejected" gatygo_transform "$tmp/notjson.json" "$tmp/bad.json" 12345 5353 255 warning 10808 s3cret
assert_exit 1 "OUT is not created on jq failure" test -e "$tmp/bad.json"

# --- the user's rules: after the provider's own, before its catch-all
UR='[{"domain":"example.org","to":"proxy"},{"domain":"rare.example","to":"direct"},{"domain":"sub.rare.example","to":"proxy"}]'
_t() { gatygo_transform "$1" "$2" 12345 5353 255 warning 10808 s3cret "${3:-$UR}"; }
_mine() { jq -c '[.routing.rules[] | select((.ruleTag // "") | startswith("gatygo-rule-"))]' "$1"; }
_mine_f() { jq -c "[.routing.rules[] | select((.ruleTag // \"\") | startswith(\"gatygo-rule-\")) | $2]" "$1"; }
jq '.[13]' "$FIX" > "$tmp/r-13.json"

_t "$tmp/in-0.json" "$tmp/u0.json"; assert_eq "0" "$?" "transform with user rules succeeds"
assert_exit 0 "xray run -test accepts it" xray run -test -c "$tmp/u0.json"
assert_exit 0 "user rules before the catch-all" jq -e --slurpfile o "$tmp/in-0.json" \
    '.routing.rules == [.routing.rules[0], .routing.rules[1]] + $o[0].routing.rules[:-1]
        + [.routing.rules[] | select((.ruleTag // "") | startswith("gatygo-rule-"))] + [$o[0].routing.rules[-1]]' "$tmp/u0.json"
assert_eq '["domain:sub.rare.example","domain:example.org","domain:rare.example"]' "$(_mine_f "$tmp/u0.json" '.domain[0]')" "more specific first, then the order of the settings"
assert_eq '[{"balancerTag":"balancer"},{"balancerTag":"balancer"},{"outboundTag":"direct"}]' \
    "$(_mine_f "$tmp/u0.json" '{balancerTag, outboundTag} | with_entries(select(.value != null))')" "tunnel = the catch-all's balancer, direct = the freedom outbound"
assert_eq "false" "$(jq '[.routing.rules[] | select((.ruleTag // "") | startswith("gatygo-rule-")) | has("ip")] | any' "$tmp/u0.json")" "no address condition with a catch-all"
assert_exit 0 "rule shape" jq -e '[.routing.rules[] | select((.ruleTag // "") | startswith("gatygo-rule-"))][0]
    == {"type":"field","ruleTag":"gatygo-rule-1","inboundTag":["tproxy","check"],"domain":["domain:sub.rare.example"],"balancerTag":"balancer"}' "$tmp/u0.json"

_t "$tmp/r-13.json" "$tmp/u13.json"
assert_eq '["proxy","proxy","direct"]' "$(_mine_f "$tmp/u13.json" '.outboundTag')" "tunnel = the catch-all's outbound"
assert_exit 0 "xray run -test accepts it (no balancer)" xray run -test -c "$tmp/u13.json"

jq '.routing.rules[-1] = {"type":"field","network":"tcp,udp","outboundTag":"direct"}' "$tmp/in-0.json" > "$tmp/cd-in.json"
_t "$tmp/cd-in.json" "$tmp/cd.json"
assert_eq '["balancer","balancer",null]' "$(_mine_f "$tmp/cd.json" '.balancerTag')" "catch-all goes direct: tunnel = the first balancer"
assert_eq "$(jq -c '.routing.rules[-1]' "$tmp/cd-in.json")" "$(jq -c '.routing.rules[-1]' "$tmp/cd.json")" "the direct catch-all stays last"

jq '.routing.rules[-1] = {"type":"field","network":"tcp,udp","outboundTag":"direct"}' "$tmp/r-13.json" > "$tmp/cd13-in.json"
_t "$tmp/cd13-in.json" "$tmp/cd13.json"
assert_eq '["proxy","proxy","direct"]' "$(_mine_f "$tmp/cd13.json" '.outboundTag')" "no balancer, catch-all direct: tunnel = the first proxy outbound"

jq '.outbounds = [{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}]
    | .routing.rules = [{"type":"field","network":"tcp,udp","outboundTag":"direct"}]' "$tmp/r-13.json" > "$tmp/nt-in.json"
_t "$tmp/nt-in.json" "$tmp/nt.json"
assert_eq '["domain:rare.example"]' "$(_mine_f "$tmp/nt.json" '.domain[0]')" "no tunnel at all: only the direct rule goes in"

jq '.outbounds |= map(select(.protocol != "freedom"))' "$tmp/r-13.json" > "$tmp/nf-in.json"
_t "$tmp/nf-in.json" "$tmp/nf.json"
assert_eq '["proxy","proxy"]' "$(_mine_f "$tmp/nf.json" '.outboundTag')" "no direct outbound: only the tunnel rules go in"

jq 'del(.routing.rules[-1])' "$tmp/in-0.json" > "$tmp/nc-in.json"
_t "$tmp/nc-in.json" "$tmp/nc.json"
assert_exit 0 "no catch-all: user rules at the end" jq -e --slurpfile o "$tmp/nc-in.json" \
    '.routing.rules[2:] == $o[0].routing.rules + [.routing.rules[] | select((.ruleTag // "") | startswith("gatygo-rule-"))]' "$tmp/nc.json"
assert_eq '[["0.0.0.0/0","::/0"],["0.0.0.0/0","::/0"],["0.0.0.0/0","::/0"]]' "$(_mine_f "$tmp/nc.json" '.ip')" \
    "no catch-all with IPIfNonMatch: they wait for the second pass, after the provider's address rules"
assert_exit 0 "xray run -test accepts it (address condition)" xray run -test -c "$tmp/nc.json"

jq 'del(.routing.rules[-1]) | .routing.domainStrategy = "AsIs"' "$tmp/in-0.json" > "$tmp/na-in.json"
_t "$tmp/na-in.json" "$tmp/na.json"
assert_eq '[null,null,null]' "$(_mine_f "$tmp/na.json" '.ip')" "no catch-all with AsIs: at the end, no address condition"
jq 'del(.routing.rules[-1]) | .routing.domainStrategy = "ipifnonmatch"' "$tmp/in-0.json" > "$tmp/nl-in.json"
_t "$tmp/nl-in.json" "$tmp/nl.json"
assert_eq "3" "$(jq '[.routing.rules[] | select(((.ruleTag // "") | startswith("gatygo-rule-")) and has("ip"))] | length' "$tmp/nl.json")" "the strategy is read in any case, as xray does"

gatygo_transform "$tmp/in-0.json" "$tmp/none-a.json" 12345 5353 255 warning 10808 s3cret '[]'
gatygo_transform "$tmp/in-0.json" "$tmp/none-b.json" 12345 5353 255 warning 10808 s3cret
assert_eq "$(sha256sum < "$tmp/none-b.json")" "$(sha256sum < "$tmp/none-a.json")" "no user rules: the same bytes as without them"
assert_eq "$(sha256sum < "$tmp/out-0.json")" "$(sha256sum < "$tmp/none-b.json")" "and as before user rules existed"
assert_exit 1 "bad user rules are rejected" gatygo_transform "$tmp/in-0.json" "$tmp/bad-ur.json" 12345 5353 255 warning 10808 s3cret 'not json'
assert_exit 1 "OUT is not created on bad user rules" test -e "$tmp/bad-ur.json"

rm -rf "$tmp"
report
