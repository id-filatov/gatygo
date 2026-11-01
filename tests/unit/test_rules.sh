#!/bin/sh
# The user's domain rules in /etc/config/gatygo: what counts as a domain, what is read, what goes.
. "$(dirname "$0")/../lib.sh"
. "$GATYGO_LIB/config.sh"
. "$GATYGO_LIB/rules.sh"

# --- a domain as the page sends it: lowercase, punycode, no scheme, port or path
for d in example.com a.b.example.co.uk xn--80ak6aa92e.com 1password.com a-b.example; do
    assert_exit 0 "a domain: $d" gatygo_rule_domain_ok "$d"
done
long=$(printf 'a%.0s' $(seq 64)).example
for d in '' localhost example..com .example.com example.com. -a.example a-.example Example.com 1.2.3.4 \
         'exa mple.com' example.123 '*.example.com' "$long"; do
    assert_exit 1 "not a domain: '$d'" gatygo_rule_domain_ok "$d"
done
assert_exit 0 "253 characters is fine" gatygo_rule_domain_ok "$(printf 'abcdefghi.%.0s' $(seq 25))abc"
assert_exit 1 "254 characters is too long" gatygo_rule_domain_ok "$(printf 'abcdefghi.%.0s' $(seq 25))abcd"

# --- the rules as the settings hold them
: > "$UCI_STUB_FILE"; : > "$SYSLOG_STUB_FILE"
assert_eq '[]' "$(gatygo_rules_json)" "no rules"
_r() { uci set "gatygo.@rule[$1]=rule"; uci set "gatygo.@rule[$1].domain=$2"; uci set "gatygo.@rule[$1].to=$3"; }
_r 0 rare.example direct; _r 1 bad..domain proxy; _r 2 other.example block; _r 3 rare.example proxy; _r 4 example.org proxy
uci set gatygo.main=gatygo
assert_eq '[{"domain":"rare.example","to":"direct"},{"domain":"example.org","to":"proxy"}]' "$(gatygo_rules_json)" \
    "valid rules in UCI order, the first of a twice-listed domain"
assert_eq "3" "$(grep -c 'skipped' "$SYSLOG_STUB_FILE")" "each skipped rule is logged"
: > "$SYSLOG_STUB_FILE"; gatygo_rules_json quiet >/dev/null
assert_eq "0" "$(grep -c 'skipped' "$SYSLOG_STUB_FILE")" "quiet logs nothing"

# --- all of them go, the rest of the settings stay
gatygo_rules_clear
assert_exit 1 "no rule section is left" uci -q get 'gatygo.@rule[0]'
assert_exit 1 "not even the last one" uci -q get 'gatygo.@rule[4].domain'
assert_eq "gatygo" "$(uci -q get gatygo.main)" "the main section stays"
assert_eq '[]' "$(gatygo_rules_json)" "nothing to read afterwards"

# --- address and subnet rules: option ip instead of domain, read in the canonical form
: > "$UCI_STUB_FILE"; : > "$SYSLOG_STUB_FILE"
_ri() { uci set "gatygo.@rule[$1]=rule"; uci set "gatygo.@rule[$1].ip=$2"; uci set "gatygo.@rule[$1].to=$3"; }
_r 0 rare.example direct; _ri 1 203.0.113.7/24 proxy; _ri 2 2001:DB8::1 direct; _ri 3 203.0.113.0/24 direct; _ri 4 256.0.0.1 proxy
_r 5 example.org proxy; uci set "gatygo.@rule[5].ip=198.51.100.7"
assert_eq '[{"domain":"rare.example","to":"direct"},{"ip":"203.0.113.0/24","to":"proxy"},{"ip":"2001:db8::1","to":"direct"}]' \
    "$(gatygo_rules_json)" "hand-edited address is normalized; a repeat after normalizing, a bad address and a domain+address rule are skipped"
assert_eq "1 1 1" "$(grep -c 'listed twice' "$SYSLOG_STUB_FILE") $(grep -c 'not an address' "$SYSLOG_STUB_FILE") $(grep -c 'not both' "$SYSLOG_STUB_FILE")" "each skip is logged with why"
_ri 6 192.0.2.1 block
assert_eq "1" "$(gatygo_rules_json >/dev/null; grep -c "rule '192.0.2.1' skipped: the direction must be proxy or direct" "$SYSLOG_STUB_FILE")" "an address rule's direction is checked too"

report
