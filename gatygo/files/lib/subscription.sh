#!/bin/sh
# Subscription body: validation and profile selection.
# The body is only ever parsed by jq; nothing from it is executed.

. "${GATYGO_LIB:-/usr/lib/gatygo}/common.sh"

# jq filter: the configs shown to the user are exactly those with a non-empty routing.balancers.
_GATYGO_JQ_BALANCED='map(select((.routing.balancers // []) | length > 0))'

# gatygo_sub_validate FILE — exit 0 iff FILE is a JSON array with at least one balancer config.
# Anything else (base64 link list, wrong UA, empty array) exits 1 with a reason on stderr.
gatygo_sub_validate() {
    if jq -e "type == \"array\" and ($_GATYGO_JQ_BALANCED | length > 0)" "$1" >/dev/null 2>&1; then
        return 0
    fi
    echo "subscription body is not a Xray JSON array with a balancer profile (check the User-Agent and the panel's subscription request rules)" >&2
    return 1
}

# gatygo_sub_profiles FILE — compact JSON [{remarks, description}] of balancer configs, in order.
gatygo_sub_profiles() {
    jq -c "$_GATYGO_JQ_BALANCED | map({remarks, description: (.meta.serverDescription // \"\")})" "$1"
}

# gatygo_sub_select FILE PROFILE OUT — write the balancer config with remarks == PROFILE to OUT
# and print its remarks. Falls back to the first balancer config when PROFILE is empty (exit 0)
# or not present (exit 3). Exit 1 and no OUT when there is no balancer config at all.
gatygo_sub_select() {
    _gatygo_chosen=$(jq -r --arg p "$2" \
        "$_GATYGO_JQ_BALANCED | (map(select(.remarks == \$p)) + .)[0] | .remarks // empty" "$1" 2>/dev/null)
    [ -n "$_gatygo_chosen" ] || return 1
    jq --arg r "$_gatygo_chosen" "$_GATYGO_JQ_BALANCED | map(select(.remarks == \$r))[0]" "$1" > "$3" || return 1
    printf '%s\n' "$_gatygo_chosen"
    [ -z "$2" ] || [ "$_gatygo_chosen" = "$2" ] || return 3
}
