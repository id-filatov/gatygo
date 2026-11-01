#!/bin/sh
# The user's own routing rules: `config rule` sections of /etc/config/gatygo, a domain (option
# domain, with its subdomains) or an address or subnet (option ip, addr.sh), and where it goes,
# proxy or direct. transform.jq puts them after the provider's own rules. The page checks what it
# saves; this checks again: the file can be edited by hand. Requires config.sh.

. "${GATYGO_LIB:-/usr/lib/gatygo}/addr.sh"

# gatygo_rule_domain_ok DOMAIN — exit 0 iff DOMAIN is a domain as the page sends it: lowercase
# letters, digits, '-' and '.', labels of 1-63 characters with no '-' at either end, at most 253
# characters, two labels at least, the last one not all digits (that is an IP address)
gatygo_rule_domain_ok() {
    [ "${#1}" -le 253 ] || return 1
    case $1 in
        *[!a-z0-9.-]* | .* | *. | *..* | -* | *- | *.-* | *-.*) return 1 ;;
        *.*) ;;
        *) return 1 ;;
    esac
    case ${1##*.} in *[!0-9]*) ;; *) return 1 ;; esac
    _gatygo_rest=$1
    while [ -n "$_gatygo_rest" ]; do
        _gatygo_label=${_gatygo_rest%%.*}
        [ "${#_gatygo_label}" -le 63 ] || return 1
        case $_gatygo_rest in *.*) _gatygo_rest=${_gatygo_rest#*.} ;; *) _gatygo_rest='' ;; esac
    done
}

# _gatygo_rules_count — the number of rule sections
_gatygo_rules_count() {
    _gatygo_n=0
    while uci -q get "gatygo.@rule[$_gatygo_n]" >/dev/null 2>&1; do _gatygo_n=$((_gatygo_n + 1)); done
    echo "$_gatygo_n"
}

# gatygo_rules_json [quiet] — print the valid rules as [{"domain", "to"}] or [{"ip", "to"}] in the
# order of the settings, an address in its canonical form. A rule that is not a domain or not an
# address, is both, goes elsewhere than proxy or direct, or names a domain or an address listed
# before is skipped, with a warning in the log unless `quiet` (the page asks often).
gatygo_rules_json() {
    _gatygo_n=$(_gatygo_rules_count) _gatygo_i=0 _gatygo_seen=' '
    while [ "$_gatygo_i" -lt "$_gatygo_n" ]; do
        _gatygo_d=$(uci -q get "gatygo.@rule[$_gatygo_i].domain" 2>/dev/null)
        _gatygo_ip=$(uci -q get "gatygo.@rule[$_gatygo_i].ip" 2>/dev/null)
        _gatygo_to=$(uci -q get "gatygo.@rule[$_gatygo_i].to" 2>/dev/null)
        _gatygo_i=$((_gatygo_i + 1))
        _gatygo_why='' _gatygo_k=domain _gatygo_rv=$_gatygo_d _gatygo_raw=$_gatygo_d
        if [ -n "$_gatygo_d" ] && [ -n "$_gatygo_ip" ]; then _gatygo_why='a rule is a domain or an address, not both'
        elif [ -n "$_gatygo_ip" ]; then
            _gatygo_k=ip _gatygo_raw=$_gatygo_ip
            _gatygo_rv=$(gatygo_addr_norm "$_gatygo_ip") || _gatygo_why='not an address'
        elif ! gatygo_rule_domain_ok "$_gatygo_d"; then _gatygo_why='not a domain'
        fi
        if [ -n "$_gatygo_why" ]; then :
        elif [ "$_gatygo_to" != proxy ] && [ "$_gatygo_to" != direct ]; then _gatygo_why='the direction must be proxy or direct'
        else case $_gatygo_seen in *" $_gatygo_rv "*) _gatygo_why='listed twice' ;; esac
        fi
        if [ -n "$_gatygo_why" ]; then
            [ "${1:-}" = quiet ] || gatygo_log warn "rule '$_gatygo_raw' skipped: $_gatygo_why"
            continue
        fi
        _gatygo_seen="$_gatygo_seen$_gatygo_rv "
        printf '%s %s %s\n' "$_gatygo_to" "$_gatygo_k" "$_gatygo_rv"
    done | jq -Rnc '[inputs | split(" ") | {(.[1]): .[2], to: .[0]}]'
}

# gatygo_rules_clear — delete every rule section (no commit). From the last one back: deleting
# the first would renumber the rest.
gatygo_rules_clear() {
    _gatygo_n=$(_gatygo_rules_count)
    while [ "$_gatygo_n" -gt 0 ]; do
        _gatygo_n=$((_gatygo_n - 1))
        uci -q delete "gatygo.@rule[$_gatygo_n]"
    done
}
