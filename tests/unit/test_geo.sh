#!/bin/sh
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
# the default geo files (Loyalsoldier's) come from the mock too, under a path of their own
export GATYGO_STATE="$tmp/state" GATYGO_ASSETS="$tmp/assets" GATYGO_RUN="$tmp/run" GATYGO_GEO_DEFAULT_BASE=http://127.0.0.1:8788/geo/default
mkdir -p "$GATYGO_STATE" "$GATYGO_ASSETS" "$tmp/geo-src" "$tmp/stage"
. "$GATYGO_LIB/config.sh"
. "$GATYGO_LIB/geo.sh"
cp "$FIXTURES/geo/geosite.dat" "$FIXTURES/geo/geoip.dat" "$tmp/geo-src/"
touch -d '2026-01-01 00:00:00' "$tmp/geo-src/geosite.dat" "$tmp/geo-src/geoip.dat"

python3 /src/tests/mock/sub_server.py 8788 "$FIXTURES/subscription.json" "$tmp/geo-src" http://127.0.0.1:8788 &
_mock=$!
for _ in $(seq 1 50); do curl -fs -o /dev/null http://127.0.0.1:8788/log && break; sleep 0.1; done
GS=http://127.0.0.1:8788/geo/geosite.dat GI=http://127.0.0.1:8788/geo/geoip.dat
_last_geo_headers() { curl -fs http://127.0.0.1:8788/log | jq -c "[.[] | select(.path == \"/geo/$1\")][-1].headers"; }

# --- URL sources
printf "GATYGO_GEOSITE_URL='http://127.0.0.1:8788/geo/geosite.dat'\nGATYGO_GEOIP_URL='http://127.0.0.1:8788/geo/geoip.dat'\n" > "$tmp/h.env"
assert_eq "http://127.0.0.1:8788/geo/geosite.dat http://127.0.0.1:8788/geo/geoip.dat" "$(gatygo_geo_urls "$tmp/h.env")" "URLs from the routing header"
assert_exit 0 "header URLs are cached" test -s "$GATYGO_STATE/geo-urls.env"
_ino=$(ls -i "$GATYGO_STATE/geo-urls.env" | awk '{print $1}')
gatygo_geo_urls "$tmp/h.env" >/dev/null
assert_eq "$_ino" "$(ls -i "$GATYGO_STATE/geo-urls.env" | awk '{print $1}')" "the same URLs again: the cache is not rewritten (the router's flash)"
printf "GATYGO_GEOSITE_URL=''\nGATYGO_GEOIP_URL=''\n" > "$tmp/empty.env"
assert_eq "http://127.0.0.1:8788/geo/geosite.dat http://127.0.0.1:8788/geo/geoip.dat" "$(gatygo_geo_urls "$tmp/empty.env")" "no header -> cached URLs"
rm "$GATYGO_STATE/geo-urls.env"
assert_exit 1 "no header, no cache -> no geo URLs" gatygo_geo_urls "$tmp/empty.env"
assert_eq "" "$(gatygo_geo_urls "$tmp/empty.env")" "nothing printed without geo URLs"
assert_exit 1 "missing headers file, no cache -> no geo URLs" gatygo_geo_urls "$tmp/missing.env"
printf "GATYGO_GEOSITE_URL='ftp://x/geosite.dat'\nGATYGO_GEOIP_URL='http://127.0.0.1:8788/geo/geoip.dat'\n" > "$tmp/bad.env"
assert_exit 1 "a non-http URL invalidates the pair" gatygo_geo_urls "$tmp/bad.env"

# --- a cached config whose geo files are gone (the state dir survives a sysupgrade, the dats do not)
printf '{"routing":{"rules":[{"domain":["geosite:ads"],"outboundTag":"block"},{"ip":["geoip:private"],"outboundTag":"direct"}]}}' > "$tmp/geo.json"
printf '{"routing":{"rules":[{"domain":["domain:example.com"],"outboundTag":"block"}]}}' > "$tmp/nogeo.json"
assert_exit 0 "the config names geo data, no dats -> missing" gatygo_geo_missing "$tmp/geo.json"
assert_exit 1 "a config without geo rules needs no dats" gatygo_geo_missing "$tmp/nogeo.json"
cp "$FIXTURES/geo/geosite.dat" "$GATYGO_ASSETS/"
assert_exit 0 "one dat of the two -> still missing" gatygo_geo_missing "$tmp/geo.json"
cp "$FIXTURES/geo/geoip.dat" "$GATYGO_ASSETS/"
assert_exit 1 "both dats in place -> nothing missing" gatygo_geo_missing "$tmp/geo.json"
assert_exit 1 "no config -> nothing to miss" gatygo_geo_missing "$tmp/none.json"
rm -f "$GATYGO_ASSETS"/*.dat

# --- due?
assert_exit 0 "due when files are missing" gatygo_geo_due

# --- first download: both staged, server mtime preserved
gatygo_geo_fetch http://127.0.0.1:8788/geo/geosite.dat http://127.0.0.1:8788/geo/geoip.dat "$tmp/stage"; _rc=$?
assert_eq "0" "$_rc" "first fetch stages files"
assert_eq "$(sha256sum < "$FIXTURES/geo/geosite.dat")" "$(sha256sum < "$tmp/stage/geosite.dat")" "geosite staged intact"
assert_eq "$(sha256sum < "$FIXTURES/geo/geoip.dat")" "$(sha256sum < "$tmp/stage/geoip.dat")" "geoip staged intact"
assert_eq "$(date -r "$tmp/geo-src/geosite.dat" +%s)" "$(date -r "$tmp/stage/geosite.dat" +%s)" "Last-Modified becomes the file mtime"

# --- installed files of unknown origin (no source record): the mtime is not trusted, unconditional GET
cp -p "$tmp/stage/"*.dat "$GATYGO_ASSETS/"; rm -f "$tmp/stage/"*.dat
touch "$GATYGO_ASSETS/"*.dat
assert_exit 1 "not due right after install" gatygo_geo_due
assert_exit 1 "no source record yet" gatygo_geo_source_matches "$GS" "$GI"
gatygo_geo_fetch "$GS" "$GI" "$tmp/stage"; _rc=$?
assert_eq "0" "$_rc" "unknown origin -> fetched again although the mtime is fresh"
assert_eq "false" "$(_last_geo_headers geosite.dat | jq 'has("if-modified-since")')" "request was unconditional"
rm -f "$tmp/stage/"*.dat

# --- installed from these URLs (recorded): conditional GET gets 304, nothing staged
gatygo_geo_record "$GS" "$GI"
assert_exit 0 "record matches the URLs" gatygo_geo_source_matches "$GS" "$GI"
assert_exit 1 "record does not match other URLs" gatygo_geo_source_matches "$GS" http://127.0.0.1:8788/geo/geoip2.dat
gatygo_geo_fetch "$GS" "$GI" "$tmp/stage"; _rc=$?
assert_eq "3" "$_rc" "unchanged on the server -> exit 3"
assert_eq "true" "$(_last_geo_headers geosite.dat | jq 'has("if-modified-since")')" "request was conditional"
assert_eq "0" "$(ls "$tmp/stage" | wc -l | tr -d ' ')" "nothing staged on 304"

# --- older than 24h -> due; newer server file -> re-staged
# explicit dates: the installed files date from Jan 1, only the server's geoip is newer (Jan 2)
touch -d '2026-01-01 00:00:00' "$GATYGO_ASSETS/geosite.dat" "$GATYGO_ASSETS/geoip.dat"
assert_exit 0 "due when a file is older than 24h" gatygo_geo_due
touch -d '2026-01-02 00:00:00' "$tmp/geo-src/geoip.dat"
gatygo_geo_fetch http://127.0.0.1:8788/geo/geosite.dat http://127.0.0.1:8788/geo/geoip.dat "$tmp/stage"; _rc=$?
assert_eq "0" "$_rc" "newer server file -> staged"
assert_exit 0 "only the newer file is staged" test -f "$tmp/stage/geoip.dat"
assert_exit 1 "unchanged file is not staged" test -f "$tmp/stage/geosite.dat"
rm -f "$tmp/stage/"*.dat

# --- the subscription names other URLs than the record: unconditional again, both staged
cp -p "$tmp/geo-src/geoip.dat" "$tmp/geo-src/geoip2.dat"
gatygo_geo_fetch "$GS" http://127.0.0.1:8788/geo/geoip2.dat "$tmp/stage"; _rc=$?
assert_eq "0" "$_rc" "other URLs -> fetched"
assert_eq "false" "$(_last_geo_headers geosite.dat | jq 'has("if-modified-since")')" "unconditional for the unchanged URL too"
assert_eq "2" "$(ls "$tmp/stage" | wc -l | tr -d ' ')" "both files staged"
rm -f "$tmp/stage/"*.dat

# --- error: stage left empty
gatygo_geo_fetch http://127.0.0.1:8788/geo/nope.dat http://127.0.0.1:8788/geo/geoip.dat "$tmp/stage" 2>/dev/null; _rc=$?
assert_eq "1" "$_rc" "404 -> exit 1"
assert_eq "0" "$(ls "$tmp/stage" | wc -l | tr -d ' ')" "stage emptied on error"
gatygo_geo_fetch http://127.0.0.1:8788/redirect http://127.0.0.1:8788/geo/geoip.dat "$tmp/stage" 2>/dev/null; _rc=$?
assert_eq "1" "$_rc" "redirect to plain http is refused"
# a download cut short still says 200: curl's own exit status tells (a slow link to 16 MB files)
gatygo_geo_fetch http://127.0.0.1:8788/geo-cut/geosite.dat http://127.0.0.1:8788/geo/geoip.dat "$tmp/stage" 2>/dev/null; _rc=$?
assert_eq "1" "$_rc" "a download cut short -> exit 1"
assert_eq "0" "$(ls "$tmp/stage" | wc -l | tr -d ' ')" "nothing of it staged"

# --- the provider switched routing off: the saved links are dropped, the files on the router stay
# (a provider config may still name geosite:/geoip:), and nothing is downloaded any more
printf "GATYGO_GEOSITE_URL='$GS'\nGATYGO_GEOIP_URL='http://127.0.0.1:8788/geo/geoip.dat'\nGATYGO_ROUTING_OFF='0'\n" > "$tmp/on.env"
gatygo_geo_urls "$tmp/on.env" >/dev/null
cp "$tmp/geo-src/geosite.dat" "$tmp/geo-src/geoip.dat" "$GATYGO_ASSETS/"
printf "GATYGO_GEOSITE_URL=''\nGATYGO_GEOIP_URL=''\nGATYGO_ROUTING_OFF='1'\n" > "$tmp/off.env"
assert_exit 1 "routing off -> no geo URLs" gatygo_geo_urls "$tmp/off.env"
assert_exit 1 "routing off -> the saved links are dropped" test -e "$GATYGO_STATE/geo-urls.env"
assert_eq "" "$(gatygo_geo_urls "$tmp/off.env")" "routing off -> nothing printed"
assert_exit 0 "routing off -> the geo files stay" test -s "$GATYGO_ASSETS/geosite.dat" -a -s "$GATYGO_ASSETS/geoip.dat"
gatygo_geo_urls "$tmp/on.env" >/dev/null
printf "GATYGO_GEOSITE_URL=''\nGATYGO_GEOIP_URL=''\nGATYGO_ROUTING_OFF='0'\n" > "$tmp/none.env"
assert_eq "$GS http://127.0.0.1:8788/geo/geoip.dat" "$(gatygo_geo_urls "$tmp/none.env")" "routing not off and no links -> the saved links"

# --- the subscription names geo rules but gives no geo files: the default ones (Loyalsoldier's)
DB=$GATYGO_GEO_DEFAULT_BASE
printf '[{"routing":{"rules":[{"domain":["geosite:category-ru"],"outboundTag":"direct"}]}}]' > "$tmp/body-geo.json"
printf '[{"routing":{"rules":[{"domain":["domain:example.com"],"outboundTag":"direct"}]}}]' > "$tmp/body-nogeo.json"
printf '[{"routing":{"rules":[{"domain":["domain:example.com"],"outboundTag":"direct"}]}},{"routing":{"rules":[{"ip":["geoip:ru"],"outboundTag":"direct"}]}}]' > "$tmp/body-one.json"
assert_exit 0 "a body with geosite: names geo" gatygo_geo_named "$tmp/body-geo.json"
assert_exit 0 "a body with geoip: names geo" gatygo_geo_named "$tmp/body-one.json"
assert_exit 1 "a body without them does not" gatygo_geo_named "$tmp/body-nogeo.json"
assert_exit 1 "no body names nothing" gatygo_geo_named "$tmp/none.json"
# the dats in place are of unknown origin (no record): not the provider's
rm -f "$GATYGO_STATE/geo-urls.env" "$GATYGO_STATE/geo-source.env"
assert_eq "$DB/geosite.dat $DB/geoip.dat" "$(gatygo_geo_urls "$tmp/empty.env" "$tmp/body-geo.json")" "geo rules, no header, no cache -> the default URLs"
assert_exit 0 "the default URLs: exit 0" gatygo_geo_urls "$tmp/empty.env" "$tmp/body-geo.json"
assert_exit 1 "the default URLs are not cached" test -e "$GATYGO_STATE/geo-urls.env"
assert_exit 1 "a body without geo rules -> no geo URLs" gatygo_geo_urls "$tmp/empty.env" "$tmp/body-nogeo.json"
assert_eq "" "$(gatygo_geo_urls "$tmp/empty.env" "$tmp/body-nogeo.json")" "a body without geo rules: nothing printed"
assert_eq "$DB/geosite.dat $DB/geoip.dat" "$(gatygo_geo_urls "$tmp/empty.env" "$tmp/body-one.json")" "geo rules in one profile of two -> the default URLs (any profile may be selected)"
assert_exit 1 "no body and no URLs -> exit 1, as before" gatygo_geo_urls "$tmp/empty.env"
assert_eq "$GS $GI" "$(gatygo_geo_urls "$tmp/h.env" "$tmp/body-geo.json")" "the provider's URLs win over the default ones"
assert_eq "$GS $GI" "$(gatygo_geo_urls "$tmp/empty.env" "$tmp/body-geo.json")" "the provider's cached URLs win too"
assert_eq "$DB/geosite.dat $DB/geoip.dat" "$(gatygo_geo_urls "$tmp/off.env" "$tmp/body-geo.json")" "routing off, geo rules -> the default URLs"
assert_exit 1 "routing off -> the cache is gone" test -e "$GATYGO_STATE/geo-urls.env"
assert_exit 1 "routing off, no geo rules -> no geo URLs" gatygo_geo_urls "$tmp/off.env" "$tmp/body-nogeo.json"
# the provider gave its geo files before and they are in place: they stay, not the default ones
gatygo_geo_record "$GS" "$GI"
cp "$tmp/geo-src/geosite.dat" "$tmp/geo-src/geoip.dat" "$GATYGO_ASSETS/"
assert_exit 1 "the provider's files in place, no URLs now -> no default URLs" gatygo_geo_urls "$tmp/empty.env" "$tmp/body-geo.json"
assert_exit 1 "routing off, the provider's files in place -> no default URLs" gatygo_geo_urls "$tmp/off.env" "$tmp/body-geo.json"
assert_exit 0 "routing off: the provider's files stay" test -s "$GATYGO_ASSETS/geosite.dat" -a -s "$GATYGO_ASSETS/geoip.dat"
rm -f "$GATYGO_ASSETS/geoip.dat"
assert_eq "$DB/geosite.dat $DB/geoip.dat" "$(gatygo_geo_urls "$tmp/empty.env" "$tmp/body-geo.json")" "the provider's files are gone (a sysupgrade) -> the default URLs"
cp "$tmp/geo-src/geoip.dat" "$GATYGO_ASSETS/"

assert_exit 0 "the default geosite URL is the default" gatygo_geo_is_default "$DB/geosite.dat"
assert_exit 1 "a provider's geosite URL is not" gatygo_geo_is_default "$GS"
rm -f "$GATYGO_STATE/geo-source.env"
assert_exit 1 "no source record -> not the default files" gatygo_geo_source_default
gatygo_geo_record "$DB/geosite.dat" "$DB/geoip.dat" default
assert_exit 0 "recorded as the default files -> the default files" gatygo_geo_source_default
gatygo_geo_record https://mirror.example/geosite.dat https://mirror.example/geoip.dat default
assert_exit 0 "recorded as the default files from another base (a later release moved it) -> still the default files" gatygo_geo_source_default
gatygo_geo_record "$DB/geosite.dat" "$DB/geoip.dat"
assert_exit 1 "recorded without the mark -> not the default files" gatygo_geo_source_default
gatygo_geo_record "$GS" "$GI"
assert_exit 1 "recorded from the provider's URLs -> not the default files" gatygo_geo_source_default

# --- after a reboot (RAM is empty, the links on the flash lead nowhere): only the default files
#     come again, the subscription is not asked
rm -f "$GATYGO_ASSETS"/*.dat; rm -rf "$GATYGO_RUN/geo"
for n in geosite.dat geoip.dat; do ln -s "$GATYGO_RUN/geo/$n" "$GATYGO_ASSETS/$n"; done
gatygo_geo_record "$DB/geosite.dat" "$DB/geoip.dat" default
_m=$(curl -fs http://127.0.0.1:8788/log | jq length)
_since() { curl -fs http://127.0.0.1:8788/log | jq --argjson m "$_m" "[.[\$m:][] | select(.path | startswith(\"$1\"))] | length"; }
gatygo_geo_restore; assert_eq "0" "$?" "restore: the default files are back"
for n in geosite.dat geoip.dat; do
    assert_eq "$GATYGO_RUN/geo/$n" "$(readlink "$GATYGO_ASSETS/$n")" "restore: the link to $n stays"
    assert_eq "$(sha256sum < "$FIXTURES/geo/$n")" "$(sha256sum < "$GATYGO_RUN/geo/$n")" "restore: $n is in RAM"
done
assert_eq "2" "$(_since /geo/default/)" "restore: both default files downloaded"
assert_eq "0" "$(_since /sub)" "restore: the subscription is not asked"
# the default files cannot be downloaded (no network yet): nothing is touched
rm -rf "$GATYGO_RUN/geo"
_db=$GATYGO_GEO_DEFAULT_BASE; GATYGO_GEO_DEFAULT_BASE=http://127.0.0.1:8788/geo-missing
gatygo_geo_record "$GATYGO_GEO_DEFAULT_BASE/geosite.dat" "$GATYGO_GEO_DEFAULT_BASE/geoip.dat" default
gatygo_geo_restore 2>/dev/null; assert_eq "1" "$?" "restore: no download -> exit 1"
assert_exit 1 "restore: nothing in RAM" test -e "$GATYGO_RUN/geo/geosite.dat"
assert_eq "$GATYGO_RUN/geo/geoip.dat" "$(readlink "$GATYGO_ASSETS/geoip.dat")" "restore: the links are left as they were"
GATYGO_GEO_DEFAULT_BASE=$_db
gatygo_geo_record "$GS" "$GI"
gatygo_geo_restore; assert_eq "2" "$?" "restore: the provider's files -> exit 2, nothing done"
assert_exit 1 "restore: the provider's files -> nothing in RAM" test -e "$GATYGO_RUN/geo/geosite.dat"

# --- an update holds its lock: the files are downloaded, but not put in place under its feet
rm -rf "$GATYGO_RUN/geo"; gatygo_geo_record "$DB/geosite.dat" "$DB/geoip.dat" default
mkdir -p "$GATYGO_RUN/update.lock"; sleep 30 & _u=$!; echo "$_u" > "$GATYGO_RUN/update.lock/pid"
gatygo_geo_restore; assert_eq "3" "$?" "restore while an update runs -> exit 3"
assert_exit 1 "restore while an update runs: nothing put in RAM" test -e "$GATYGO_RUN/geo/geosite.dat"
kill "$_u"; wait "$_u" 2>/dev/null; rm -rf "$GATYGO_RUN/update.lock"

# --- the VPN waits for the default files: they come in the background, away from procd's lock
#     (rc.common holds it on fd 1000), once a minute until they are there; then the service starts
export GATYGO_INIT=/src/tests/stubs/gatygo-init GATYGO_INIT_LOG="$tmp/init.log" GATYGO_GEO_RETRY_DELAY=1
uci set gatygo.main.enabled=1
_wait() { _gatygo_env_get "$GATYGO_RUN/geo-wait" "$1"; }
_gatygo_geo_wait downloading
assert_eq "downloading  1" "$(_wait GATYGO_GEO_WAIT) $(_wait GATYGO_GEO_NEXT) $(_wait GATYGO_GEO_BLOCK)" "the wait as the page reads it: downloading, no next try yet, closed"
uci set gatygo.main.on_crash=direct; _gatygo_geo_wait failed 1795800000
assert_eq "failed 1795800000 0" "$(_wait GATYGO_GEO_WAIT) $(_wait GATYGO_GEO_NEXT) $(_wait GATYGO_GEO_BLOCK)" "failed, the next try, open"
uci delete gatygo.main.on_crash; rm -f "$GATYGO_RUN/geo-wait"
_lines() { grep -c "$1" "$SYSLOG_STUB_FILE"; }
mkdir -p "$tmp/geo-away"; mv "$tmp/geo-src/"*.dat "$tmp/geo-away/"
rm -f "$GATYGO_RUN/stopped"; : > "$GATYGO_INIT_LOG"
_e0=$(_lines "could not be downloaded; trying again every minute$"); _d0=$(_lines 'download of geosite.dat failed')
exec 1000>"$tmp/procd.lock"
gatygo_geo_restore_later start; _p=$(cat "$GATYGO_RUN/geo-retry")
exec 1000>&-
assert_eq "" "$(readlink "/proc/$_p/fd/1000")" "the download does not hold the init script's lock"
# the first try may have failed already: either state tells the page the VPN waits
case $(_wait GATYGO_GEO_WAIT) in downloading | failed) _t_ok ;; *) _t_bad "the page is told the VPN waits: $(_wait GATYGO_GEO_WAIT)" ;; esac
assert_eq "1" "$(_wait GATYGO_GEO_BLOCK)" "and that the home network is closed"
gatygo_geo_restore_later start
assert_eq "$_p" "$(cat "$GATYGO_RUN/geo-retry")" "one at a time"
sleep 4
assert_eq "failed" "$(_wait GATYGO_GEO_WAIT)" "no files yet: the page is told"
assert_exit 0 "and when the next try is" test "$(_wait GATYGO_GEO_NEXT)" -ge "$(date +%s)"
assert_eq "$((_e0 + 1)) $((_d0 + 1))" "$(_lines "could not be downloaded; trying again every minute$") $(_lines 'download of geosite.dat failed')" "only the first failed try is logged"
assert_eq "" "$(cat "$GATYGO_INIT_LOG")" "no start while the files are missing"
mv "$tmp/geo-away/"*.dat "$tmp/geo-src/"
wait "$_p"
assert_eq "start" "$(cat "$GATYGO_INIT_LOG")" "the files are there: the service is started"
for n in geosite.dat geoip.dat; do
    assert_eq "$(sha256sum < "$FIXTURES/geo/$n")" "$(sha256sum < "$GATYGO_RUN/geo/$n")" "the download in the background put $n in RAM"
done
assert_exit 1 "the wait is over: nothing to tell the page" test -e "$GATYGO_RUN/geo-wait"
assert_exit 1 "the download is over: its note is gone" test -e "$GATYGO_RUN/geo-retry"
assert_eq "1" "$(_lines "geo: Loyalsoldier's geo files are in place again$")" "the log says they are back"
# stopped by hand meanwhile: no start
rm -rf "$GATYGO_RUN/geo"; mv "$tmp/geo-src/"*.dat "$tmp/geo-away/"; : > "$GATYGO_INIT_LOG"
gatygo_geo_restore_later start; _p=$(cat "$GATYGO_RUN/geo-retry")
touch "$GATYGO_RUN/stopped"
wait "$_p"
assert_eq "" "$(cat "$GATYGO_INIT_LOG")" "stopped by hand meanwhile: no start"
assert_exit 1 "stopped by hand: the download ends" test -e "$GATYGO_RUN/geo-retry"
rm -f "$GATYGO_RUN/stopped"
# switched off in the settings (or the subscription deleted): it ends as well
uci set gatygo.main.enabled=0
gatygo_geo_restore_later start; _p=$(cat "$GATYGO_RUN/geo-retry"); wait "$_p"
assert_eq "" "$(cat "$GATYGO_INIT_LOG")" "switched off: no start"
uci set gatygo.main.enabled=1; mv "$tmp/geo-away/"*.dat "$tmp/geo-src/"
# the VPN runs on a profile without geo rules: the files follow for the others, nothing waits
gatygo_geo_restore_later; _p=$(cat "$GATYGO_RUN/geo-retry")
assert_exit 1 "nothing waits: the page is not told" test -e "$GATYGO_RUN/geo-wait"
wait "$_p"
assert_exit 0 "nothing waits: the files come all the same" test -s "$GATYGO_RUN/geo/geoip.dat"
assert_eq "" "$(cat "$GATYGO_INIT_LOG")" "nothing waits: no start"
# the download runs for another profile when the VPN comes to wait for it (Start on a profile with
# geo rules): the same download, now starting the service, and the page told as the settings are
rm -rf "$GATYGO_RUN/geo"; mv "$tmp/geo-src/"*.dat "$tmp/geo-away/"; : > "$GATYGO_INIT_LOG"
uci set gatygo.main.on_crash=direct
gatygo_geo_restore_later; _p=$(cat "$GATYGO_RUN/geo-retry")
gatygo_geo_restore_later start
assert_eq "$_p" "$(cat "$GATYGO_RUN/geo-retry")" "the VPN comes to wait: the same download"
assert_exit 0 "the page is told now" test -e "$GATYGO_RUN/geo-wait"
uci delete gatygo.main.on_crash
sleep 2
assert_eq "failed 1" "$(_wait GATYGO_GEO_WAIT) $(_wait GATYGO_GEO_BLOCK)" "the page is told as the settings are now (block)"
mv "$tmp/geo-away/"*.dat "$tmp/geo-src/"
wait "$_p"
assert_eq "start" "$(cat "$GATYGO_INIT_LOG")" "the files are there: the service is started"

kill $_mock 2>/dev/null; rm -rf "$tmp"
report
