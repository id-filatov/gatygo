#!/bin/sh
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state"
mkdir -p "$GATYGO_STATE"; : > "$UCI_STUB_FILE"; : > "$SYSLOG_STUB_FILE"
. "$GATYGO_LIB/config.sh"
. "$GATYGO_LIB/suburl.sh"
F="$GATYGO_STATE/sub-urls.env"
_u() { _gatygo_env_get "$F" "GATYGO_URLS_$1"; }
_all() { printf '%s|%s|%s|%s' "$(_u FOR)" "$(_u FALLBACK)" "$(_u PREVIOUS)" "$(_u MOVED)"; }
# _hdr NEW_URL NEW_DOMAIN FALLBACK — a headers.env with the three address headers
_hdr() {
    {
        echo "GATYGO_NEW_URL=$(gatygo_shquote "$1")"
        echo "GATYGO_NEW_DOMAIN=$(gatygo_shquote "$2")"
        echo "GATYGO_FALLBACK_URL=$(gatygo_shquote "$3")"
    } > "$tmp/h.env"
}
_rec() { gatygo_suburl_record "$@" "$tmp/h.env" 2>>"$tmp/stderr.log"; }
M=https://sub.example.com/s/1
N=https://sub.example.net/s/2
B=https://backup.example.com/s/1

# --- new-domain: only the host name changes, the port only when the value has one
_d() { gatygo_suburl_domain "$1" "$2"; }
assert_eq "https://new.example.org/sub/abc" "$(_d https://old.example.com/sub/abc new.example.org)" "domain: the host is replaced"
assert_eq "https://new.example.org:2096/sub/abc?x=1" "$(_d 'https://old.example.com:2096/sub/abc?x=1' new.example.org)" "domain: the port stays"
assert_eq "https://new.example.org:8443/sub" "$(_d https://old.example.com:2096/sub new.example.org:8443)" "domain: a port in the value replaces it"
assert_eq "https://new.example.org" "$(_d https://old.example.com new.example.org)" "domain: an address without a path"
assert_eq "http://new.example.org:8080/s" "$(_d http://192.0.2.1:8080/s new.example.org)" "domain: an address by IP"
assert_eq "https://u:p@new.example.org/s" "$(_d https://u:p@old.example.com/s new.example.org)" "domain: a user in the address stays"
for _v in https://new.example.org new.example.org/x user@new.example.org 'new example.org' '' -new.example.org new.example.org:99999x; do
    assert_exit 1 "domain refuses '$_v'" gatygo_suburl_domain https://old.example.com/s "$_v"
done
assert_exit 1 "domain: an IPv6 host is left alone" gatygo_suburl_domain 'https://[2001:db8::1]/s' new.example.org
assert_exit 1 "domain: not an address" gatygo_suburl_domain old.example.com/s new.example.org

# --- record: the provider moves the subscription by new-url
uci set gatygo.main.sub_url="$M"
_hdr "$N" "" "$B"
_rec "$M" "$M"
assert_eq "$N" "$(uci get gatygo.main.sub_url)" "new-url: the link is the new one"
assert_eq "$N|$B|$M" "$(_u FOR)|$(_u FALLBACK)|$(_u PREVIOUS)" "the file belongs to the new link; the old one is the previous"
case $(_u MOVED) in '' | *[!0-9]*) _t_bad "the move is noted with its time: '$(_u MOVED)'" ;; *) _t_ok ;; esac
assert_eq "-rw-------" "$(ls -l "$F" | cut -c1-10)" "sub-urls.env is 0600"
assert_eq "1" "$(grep -c 'moved the subscription to a new address' "$SYSLOG_STUB_FILE")" "one line says so"
_moved=$(_u MOVED)

# --- the new link failed and the previous one answered: the previous one stays
_hdr "" "" "$B"
_rec "$N" "$M"
assert_eq "$N|$B|$M|$_moved" "$(_all)" "downloaded from the previous address: it is kept"

# --- the first good update from the new link drops the previous one; the move stays noted
_rec "$N" "$N"
assert_eq "$N|$B||$_moved" "$(_all)" "downloaded from the link: the previous address goes"

# --- the provider keeps sending the address in use: no move
_hdr "$N" "" ""
_rec "$N" "$N"
assert_eq "$N" "$(uci get gatygo.main.sub_url)" "new-url equal to the link: nothing changes"
assert_eq "$N|||$_moved" "$(_all)" "and the move stays the one before; a fallback no longer sent is forgotten"
assert_eq "1" "$(grep -c 'moved the subscription' "$SYSLOG_STUB_FILE")" "no second move logged"

# --- bad values are ignored with a word in the log
_hdr 'javascript:alert(1)' "" 'ftp://backup.example.com/s'
_rec "$N" "$N"
_hdr "" 'evil.example/x' ""
_rec "$N" "$N"
assert_eq "$N" "$(uci get gatygo.main.sub_url)" "bad new-url and new-domain: the link stays"
assert_eq "$N|||$_moved" "$(_all)" "and nothing is noted"
assert_eq "1 1 1" "$(grep -c 'ignored new-url' "$SYSLOG_STUB_FILE") $(grep -c 'ignored new-domain' "$SYSLOG_STUB_FILE") $(grep -c 'ignored fallback-url' "$SYSLOG_STUB_FILE")" "each is logged once"

# --- new-domain moves the link to the same address on another host
_hdr "" sub.example.org ""
_rec "$N" "$N"
assert_eq "https://sub.example.org/s/2" "$(uci get gatygo.main.sub_url)" "new-domain: the host of the link changes"
assert_eq "https://sub.example.org/s/2||$N" "$(_u FOR)|$(_u FALLBACK)|$(_u PREVIOUS)" "the old link is the previous"
assert_eq "both" "$(_hdr "$M" other.example.org ""; _rec "https://sub.example.org/s/2" "https://sub.example.org/s/2"; [ "$(uci get gatygo.main.sub_url)" = "$M" ] && echo both)" "new-url wins over new-domain"
uci set gatygo.main.sub_url="$M"

# --- the settings cannot be written: the link and the file stay as they were
_hdr "" "" ""
_rec "$M" "$M"
_before=$(_all)
_hdr "$N" "" ""
UCI_STUB_COMMIT_RC=1 gatygo_suburl_record "$M" "$M" "$tmp/h.env" 2>>"$tmp/stderr.log"
assert_eq "$_before" "$(_all)" "commit failed: the file still belongs to the link"
assert_eq "1" "$(grep -c 'could not save the new subscription address' "$SYSLOG_STUB_FILE")" "and the log says so"
uci set gatygo.main.sub_url="$M"

# --- the link was changed by hand while the update ran: the old provider's move does not undo it
H=https://hand.example.org/s/9
uci set gatygo.main.sub_url="$H"
_before=$(cat "$F")
_hdr "$N" "" "$B"
_rec "$M" "$M"
assert_eq "$H" "$(uci get gatygo.main.sub_url)" "a link changed by hand during the update stays"
assert_eq "$_before" "$(cat "$F")" "and the old link's file is left alone"
uci set gatygo.main.sub_url="$M"

# --- spares: the fallback, then the previous address, only for the link they came with
printf "GATYGO_URLS_FOR=%s\nGATYGO_URLS_FALLBACK=%s\nGATYGO_URLS_PREVIOUS=%s\nGATYGO_URLS_MOVED=''\n" \
    "$(gatygo_shquote "$M")" "$(gatygo_shquote "$B")" "$(gatygo_shquote "$N")" > "$F"
assert_eq "fallback $B
previous $N" "$(gatygo_suburl_spares "$M")" "spares: fallback first, then previous"
assert_eq "" "$(gatygo_suburl_spares "$N")" "spares: another link (changed by hand) gets none"
printf "GATYGO_URLS_FOR=%s\nGATYGO_URLS_FALLBACK=%s\nGATYGO_URLS_PREVIOUS=%s\nGATYGO_URLS_MOVED=''\n" \
    "$(gatygo_shquote "$M")" "$(gatygo_shquote "$M")" "$(gatygo_shquote "$B")" > "$F"
assert_eq "previous $B" "$(gatygo_suburl_spares "$M")" "spares: the link itself is not a spare"
printf "GATYGO_URLS_FOR=%s\nGATYGO_URLS_FALLBACK=%s\nGATYGO_URLS_PREVIOUS=%s\nGATYGO_URLS_MOVED=''\n" \
    "$(gatygo_shquote "$M")" "$(gatygo_shquote "$B")" "$(gatygo_shquote "$B")" > "$F"
assert_eq "fallback $B" "$(gatygo_suburl_spares "$M")" "spares: the same address once"
rm -f "$F"
assert_eq "" "$(gatygo_suburl_spares "$M")" "spares: no file, none"

# --- the move notice: shown for its link, gone once hidden
assert_exit 0 "dismiss without a file" gatygo_suburl_dismiss
printf "GATYGO_URLS_FOR=%s\nGATYGO_URLS_FALLBACK=%s\nGATYGO_URLS_PREVIOUS=%s\nGATYGO_URLS_MOVED='1790000000'\n" \
    "$(gatygo_shquote "$M")" "$(gatygo_shquote "$B")" "$(gatygo_shquote "$N")" > "$F"
assert_eq "1790000000" "$(gatygo_suburl_moved "$M")" "moved: the time for its link"
assert_eq "" "$(gatygo_suburl_moved "$N")" "moved: nothing for another link"
gatygo_suburl_dismiss
assert_eq "" "$(gatygo_suburl_moved "$M")" "dismissed: no notice"
assert_eq "$M|$B|$N|" "$(_all)" "dismiss keeps the rest"

# --- an update that changes nothing does not write the file (flash wear)
_hdr "" "" "$B"
_rec "$M" "$M"
touch -d '2020-01-01 00:00:00' "$F"
_rec "$M" "$M"
assert_eq "2020" "$(date -r "$F" +%Y)" "unchanged: the file is not rewritten"

# --- no address ever reaches the log or stderr
assert_eq "0" "$(cat "$SYSLOG_STUB_FILE" "$tmp/stderr.log" | grep -cE 'example\.|127\.0\.0\.1')" "the log never shows an address"

rm -rf "$tmp"
report
