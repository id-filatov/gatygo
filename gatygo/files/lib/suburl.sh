#!/bin/sh
# The subscription's address: following the provider when it moves the subscription (new-url,
# new-domain), and the spare addresses an update tries when the link does not answer.
#
# $GATYGO_STATE/sub-urls.env belongs to one link, GATYGO_URLS_FOR. It keeps the fallback-url of
# the last good answer, the previous link after a move (until the new link has answered once: a
# move to a dead address must not cut the router off), and when the provider last moved the
# subscription (the page's "new address" notice; emptied when the notice is hidden). A link
# changed by hand (the settings page, `gatygo connect`) is not the one the file is for: its
# spares are never tried and no notice is shown, so a dead new link never pulls in the old
# provider's subscription.
#
# Addresses never go to the log or stderr: the subscription link is a secret.
# Requires config.sh (sourced by the caller).

# _gatygo_su_load MAIN — the file's values into _gatygo_su_fb, _gatygo_su_prev, _gatygo_su_moved
# when the file belongs to MAIN; empty otherwise
_gatygo_su_load() {
    _gatygo_su_fb='' _gatygo_su_prev='' _gatygo_su_moved=''
    _gatygo_su_f="$GATYGO_STATE/sub-urls.env"
    [ -f "$_gatygo_su_f" ] || return 0
    [ "$(_gatygo_env_get "$_gatygo_su_f" GATYGO_URLS_FOR)" = "$1" ] || return 0
    _gatygo_su_fb=$(_gatygo_env_get "$_gatygo_su_f" GATYGO_URLS_FALLBACK)
    _gatygo_su_prev=$(_gatygo_env_get "$_gatygo_su_f" GATYGO_URLS_PREVIOUS)
    _gatygo_su_moved=$(_gatygo_env_get "$_gatygo_su_f" GATYGO_URLS_MOVED)
}

# _gatygo_su_write FOR FALLBACK PREVIOUS MOVED — rewrite the file (0600, atomic) when it changes
_gatygo_su_write() {
    _gatygo_su_f="$GATYGO_STATE/sub-urls.env"
    _gatygo_su_new=$(printf 'GATYGO_URLS_FOR=%s\nGATYGO_URLS_FALLBACK=%s\nGATYGO_URLS_PREVIOUS=%s\nGATYGO_URLS_MOVED=%s' \
        "$(gatygo_shquote "$1")" "$(gatygo_shquote "$2")" "$(gatygo_shquote "$3")" "$(gatygo_shquote "$4")")
    [ "$(cat "$_gatygo_su_f" 2>/dev/null)" = "$_gatygo_su_new" ] && return 0
    mkdir -p "$GATYGO_STATE"
    printf '%s\n' "$_gatygo_su_new" > "$_gatygo_su_f.tmp" && chmod 600 "$_gatygo_su_f.tmp" \
        && mv "$_gatygo_su_f.tmp" "$_gatygo_su_f"
}

# gatygo_suburl_domain URL HOSTPORT — URL with its host name replaced by HOSTPORT's; the port
# changes only when HOSTPORT has one. Exit 1 (nothing printed) for a HOSTPORT that is not a host
# name with an optional port, and for a URL without scheme://host or with an [IPv6] host.
gatygo_suburl_domain() {
    printf '%s' "$2" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$' || return 1
    case $1 in *://*) ;; *) return 1 ;; esac
    _gatygo_su_scheme=${1%%://*}
    _gatygo_su_rest=${1#*://}
    _gatygo_su_auth=${_gatygo_su_rest%%[/?#]*}
    _gatygo_su_tail=${_gatygo_su_rest#"$_gatygo_su_auth"}
    case $_gatygo_su_auth in
        *@*) _gatygo_su_user="${_gatygo_su_auth%@*}@" _gatygo_su_hp=${_gatygo_su_auth##*@} ;;
        *) _gatygo_su_user='' _gatygo_su_hp=$_gatygo_su_auth ;;
    esac
    case $_gatygo_su_hp in '' | \[*) return 1 ;; esac
    _gatygo_su_port=''
    case $_gatygo_su_hp in *:*) _gatygo_su_port=":${_gatygo_su_hp##*:}" ;; esac
    case $2 in
        *:*) _gatygo_su_hp=$2 ;;
        *) _gatygo_su_hp="$2$_gatygo_su_port" ;;
    esac
    printf '%s\n' "$_gatygo_su_scheme://$_gatygo_su_user$_gatygo_su_hp$_gatygo_su_tail"
}

# gatygo_suburl_spares MAIN — the addresses to try when MAIN does not answer, one per line as
# "fallback URL" then "previous URL"; only the ones kept for MAIN, never MAIN itself, each once
gatygo_suburl_spares() {
    _gatygo_su_load "$1"
    _gatygo_su_seen=$1
    for _gatygo_su_kind in fallback previous; do
        if [ "$_gatygo_su_kind" = fallback ]; then _gatygo_su_u=$_gatygo_su_fb; else _gatygo_su_u=$_gatygo_su_prev; fi
        [ -n "$_gatygo_su_u" ] || continue
        [ "$_gatygo_su_u" != "$1" ] && [ "$_gatygo_su_u" != "$_gatygo_su_seen" ] || continue
        printf '%s %s\n' "$_gatygo_su_kind" "$_gatygo_su_u"
        _gatygo_su_seen=$_gatygo_su_u
    done
}

# gatygo_suburl_record MAIN USED HEADERS_ENV — after a good update: MAIN is the link the update
# started with, USED the address the subscription came from. Keeps the answer's fallback-url,
# drops the previous link once MAIN itself has answered, and follows a move (new-url first, then
# new-domain) by writing the new link to the settings. No reload is triggered: the next update
# uses the new link. Always exit 0; what is ignored and why goes to the log.
# A link changed by hand while the update ran (Save & Apply waits for it) is left alone: the old
# link's answer neither moves it nor writes the file.
gatygo_suburl_record() {
    [ "$(uci -q get gatygo.main.sub_url 2>/dev/null)" = "$1" ] || return 0
    _gatygo_su_load "$1"
    _gatygo_su_nu=$(_gatygo_env_get "$3" GATYGO_NEW_URL)
    _gatygo_su_nd=$(_gatygo_env_get "$3" GATYGO_NEW_DOMAIN)
    _gatygo_su_nf=$(_gatygo_env_get "$3" GATYGO_FALLBACK_URL)
    _gatygo_su_keep=''
    if [ -n "$_gatygo_su_nf" ]; then
        _gatygo_su_keep=$(gatygo_http_url "$_gatygo_su_nf") || gatygo_log warn "ignored fallback-url: not an http(s) address"
    fi
    _gatygo_su_to=''
    if [ -n "$_gatygo_su_nu" ]; then
        _gatygo_su_to=$(gatygo_http_url "$_gatygo_su_nu") || gatygo_log warn "ignored new-url: not an http(s) address"
    elif [ -n "$_gatygo_su_nd" ]; then
        _gatygo_su_to=$(gatygo_suburl_domain "$1" "$_gatygo_su_nd") || gatygo_log warn "ignored new-domain: not a host name"
    fi
    _gatygo_su_was=''
    [ "$2" = "$1" ] || _gatygo_su_was=$_gatygo_su_prev
    if [ -n "$_gatygo_su_to" ] && [ "$_gatygo_su_to" != "$1" ]; then
        if uci set "gatygo.main.sub_url=$_gatygo_su_to" 2>/dev/null && uci commit gatygo 2>/dev/null; then
            _gatygo_su_write "$_gatygo_su_to" "$_gatygo_su_keep" "$1" "$(date +%s)"
            gatygo_log info "the provider moved the subscription to a new address"
            return 0
        fi
        uci -q revert gatygo.main.sub_url >/dev/null 2>&1
        gatygo_log warn "could not save the new subscription address; keeping the current one"
    fi
    _gatygo_su_write "$1" "$_gatygo_su_keep" "$_gatygo_su_was" "$_gatygo_su_moved"
    return 0
}

# gatygo_suburl_moved MAIN — when the provider moved the subscription to MAIN (unix time), if the
# notice is not hidden; nothing otherwise
gatygo_suburl_moved() {
    _gatygo_su_load "$1"
    [ -z "$_gatygo_su_moved" ] || printf '%s\n' "$_gatygo_su_moved"
}

# gatygo_suburl_dismiss — hide the "new address" notice; the spares stay
gatygo_suburl_dismiss() {
    _gatygo_su_f="$GATYGO_STATE/sub-urls.env"
    [ -f "$_gatygo_su_f" ] || return 0
    _gatygo_su_write "$(_gatygo_env_get "$_gatygo_su_f" GATYGO_URLS_FOR)" "$(_gatygo_env_get "$_gatygo_su_f" GATYGO_URLS_FALLBACK)" \
        "$(_gatygo_env_get "$_gatygo_su_f" GATYGO_URLS_PREVIOUS)" ''
}
