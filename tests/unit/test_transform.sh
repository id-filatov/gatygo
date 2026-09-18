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
    assert_exit 0 "tproxy inbound shape: $name" jq -e \
        '.inbounds[0] | .protocol == "dokodemo-door" and .listen == "0.0.0.0" and .port == 12345
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

rm -rf "$tmp"
report
