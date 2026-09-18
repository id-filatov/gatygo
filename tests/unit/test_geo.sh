#!/bin/sh
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state" GATYGO_ASSETS="$tmp/assets"
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

kill $_mock 2>/dev/null; rm -rf "$tmp"
report
