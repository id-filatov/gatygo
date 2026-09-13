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

# --- URL sources
printf "GATYGO_GEOSITE_URL='http://127.0.0.1:8788/geo/geosite.dat'\nGATYGO_GEOIP_URL='http://127.0.0.1:8788/geo/geoip.dat'\n" > "$tmp/h.env"
assert_eq "http://127.0.0.1:8788/geo/geosite.dat http://127.0.0.1:8788/geo/geoip.dat" "$(gatygo_geo_urls "$tmp/h.env")" "URLs from the routing header"
assert_exit 0 "header URLs are cached" test -s "$GATYGO_STATE/geo-urls.env"
printf "GATYGO_GEOSITE_URL=''\nGATYGO_GEOIP_URL=''\n" > "$tmp/empty.env"
assert_eq "http://127.0.0.1:8788/geo/geosite.dat http://127.0.0.1:8788/geo/geoip.dat" "$(gatygo_geo_urls "$tmp/empty.env")" "no header -> cached URLs"
rm "$GATYGO_STATE/geo-urls.env"
assert_eq "https://geo.example.com/geosite.dat https://geo.example.com/geoip.dat" "$(gatygo_geo_urls "$tmp/empty.env")" "no header, no cache -> built-in defaults"
assert_eq "https://geo.example.com/geosite.dat https://geo.example.com/geoip.dat" "$(gatygo_geo_urls "$tmp/missing.env")" "missing headers file -> defaults"
printf "GATYGO_GEOSITE_URL='ftp://x/geosite.dat'\nGATYGO_GEOIP_URL='http://127.0.0.1:8788/geo/geoip.dat'\n" > "$tmp/bad.env"
assert_eq "https://geo.example.com/geosite.dat https://geo.example.com/geoip.dat" "$(gatygo_geo_urls "$tmp/bad.env")" "a non-http URL invalidates the pair"

# --- due?
assert_exit 0 "due when files are missing" gatygo_geo_due

# --- first download: both staged, server mtime preserved
gatygo_geo_fetch http://127.0.0.1:8788/geo/geosite.dat http://127.0.0.1:8788/geo/geoip.dat "$tmp/stage"; _rc=$?
assert_eq "0" "$_rc" "first fetch stages files"
assert_eq "$(sha256sum < "$FIXTURES/geo/geosite.dat")" "$(sha256sum < "$tmp/stage/geosite.dat")" "geosite staged intact"
assert_eq "$(sha256sum < "$FIXTURES/geo/geoip.dat")" "$(sha256sum < "$tmp/stage/geoip.dat")" "geoip staged intact"
assert_eq "$(stat -c %Y "$tmp/geo-src/geosite.dat")" "$(stat -c %Y "$tmp/stage/geosite.dat")" "Last-Modified becomes the file mtime"

# --- installed and fresh: not due, conditional GET gets 304, nothing staged
cp -p "$tmp/stage/"*.dat "$GATYGO_ASSETS/"; rm -f "$tmp/stage/"*.dat
touch "$GATYGO_ASSETS/"*.dat
assert_exit 1 "not due right after install" gatygo_geo_due
gatygo_geo_fetch http://127.0.0.1:8788/geo/geosite.dat http://127.0.0.1:8788/geo/geoip.dat "$tmp/stage"; _rc=$?
assert_eq "3" "$_rc" "unchanged on the server -> exit 3"
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

# --- error: stage left empty
gatygo_geo_fetch http://127.0.0.1:8788/geo/nope.dat http://127.0.0.1:8788/geo/geoip.dat "$tmp/stage" 2>/dev/null; _rc=$?
assert_eq "1" "$_rc" "404 -> exit 1"
assert_eq "0" "$(ls "$tmp/stage" | wc -l | tr -d ' ')" "stage emptied on error"

kill $_mock 2>/dev/null; rm -rf "$tmp"
report
