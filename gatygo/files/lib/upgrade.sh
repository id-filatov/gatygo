#!/bin/sh
# Upgrading gatygo itself from the LuCI page: the router learns about a newer GitHub release
# (releases/latest, at most once a day) and the page offers it next to the version number.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/service.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/core.sh"

# the packages that own the same proxy rules: CONFLICTS in install.sh
GATYGO_UPGRADE_CONFLICTS="luci-app-passwall luci-app-passwall2 luci-app-openclash luci-app-homeproxy"

# gatygo_upgrade_api / gatygo_upgrade_raw — base URLs of the releases API and of the raw files of
# a tag. Hidden UCI options (release_api, release_raw) point them elsewhere: a fork, the lab.
gatygo_upgrade_api() {
    _gatygo_v=$(gatygo_cfg release_api https://api.github.com/repos/id-filatov/gatygo/releases)
    printf '%s\n' "${_gatygo_v%/}"
}

gatygo_upgrade_raw() {
    _gatygo_v=$(gatygo_cfg release_raw https://raw.githubusercontent.com/id-filatov/gatygo)
    printf '%s\n' "${_gatygo_v%/}"
}

# _gatygo_upgrade_version_ok V — exit 0 iff V is a release version, yyyymmdd.hhmm (tools/release.sh)
_gatygo_upgrade_version_ok() {
    case $1 in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9][0-9]) return 0 ;; esac
    return 1
}

# gatygo_upgrade_newer A B — exit 0 iff both are release versions and A is the later one
gatygo_upgrade_newer() {
    _gatygo_upgrade_version_ok "$1" && _gatygo_upgrade_version_ok "$2" || return 1
    [ "${1%.*}" -gt "${2%.*}" ] && return 0
    [ "${1%.*}" -eq "${2%.*}" ] && [ "${1#*.}" -gt "${2#*.}" ]
}

# gatygo_upgrade_release FILE — a GitHub release JSON boiled down to one line:
# {"version":…,"gatygo":{"url":…,"sha256":…},"luci":{…}}. sha256 is the asset's digest when
# GitHub gives one, "" otherwise. Exit 1 (nothing printed) without a vyyyymmdd.hhmm tag or
# without one of the two packages.
gatygo_upgrade_release() {
    _gatygo_r=$(jq -c '
        def asset($p): first(.assets[]? | select((.name // "") | startswith($p))
            | select((.browser_download_url // "") != "")
            | {url: .browser_download_url,
               sha256: ((.digest // "") | if startswith("sha256:") then ltrimstr("sha256:") else "" end)});
        (.tag_name // "") as $t
        | select($t | startswith("v"))
        | {version: ($t | ltrimstr("v")), gatygo: asset("gatygo-"), luci: asset("luci-app-gatygo-")}' "$1" 2>/dev/null) || return 1
    [ -n "$_gatygo_r" ] || return 1
    _gatygo_upgrade_version_ok "$(printf '%s' "$_gatygo_r" | jq -r .version)" || return 1
    printf '%s\n' "$_gatygo_r"
}

# gatygo_upgrade_due — exit 0 when the latest release was never asked for or a day has passed
gatygo_upgrade_due() {
    _gatygo_m=$(date -r "$GATYGO_STATE/upgrade-latest.json" +%s 2>/dev/null) || return 0
    [ $(($(date +%s) - _gatygo_m)) -ge 86400 ]
}

# gatygo_upgrade_check — ask GitHub for the latest release and keep the answer in
# $GATYGO_STATE/upgrade-latest.json: {"checked":<epoch>,"version":<v>|null}. No answer: the
# version known before stays, the time is renewed all the same (one try a day). Another check
# running: exit 0 without asking.
gatygo_upgrade_check() {
    gatygo_lock upgrade-check || return 0
    _gatygo_uf=$GATYGO_STATE/upgrade-latest.json
    _gatygo_uv=$(jq -r '.version // empty' "$_gatygo_uf" 2>/dev/null)
    _gatygo_urc=1
    if curl -fsSL --connect-timeout 15 --max-time 60 -o "$GATYGO_RUN/upgrade-latest.tmp" "$(gatygo_upgrade_api)/latest" 2>/dev/null \
        && _gatygo_ur=$(gatygo_upgrade_release "$GATYGO_RUN/upgrade-latest.tmp"); then
        _gatygo_uv=$(printf '%s' "$_gatygo_ur" | jq -r .version)
        _gatygo_urc=0
    else
        gatygo_log warn "upgrade: no answer about the latest release"
    fi
    rm -f "$GATYGO_RUN/upgrade-latest.tmp"
    mkdir -p "$GATYGO_STATE"
    (umask 077; jq -nc --argjson checked "$(date +%s)" --arg v "$_gatygo_uv" \
        '{checked: $checked, version: (if $v == "" then null else $v end)}' > "$_gatygo_uf.tmp") \
        && mv "$_gatygo_uf.tmp" "$_gatygo_uf"
    gatygo_unlock upgrade-check
    return $_gatygo_urc
}

# gatygo_upgrade_status_json — what the page needs: the latest known release, whether it is
# newer than this one, and the progress of an upgrade ($GATYGO_RUN/upgrade.json) when there is one
gatygo_upgrade_status_json() {
    _gatygo_ul=$(jq -r '.version // empty' "$GATYGO_STATE/upgrade-latest.json" 2>/dev/null)
    _gatygo_ua=false
    gatygo_upgrade_newer "$_gatygo_ul" "$GATYGO_VERSION" && _gatygo_ua=true
    _gatygo_urun=$(jq -c . "$GATYGO_RUN/upgrade.json" 2>/dev/null) || _gatygo_urun=''
    jq -nc --arg latest "$_gatygo_ul" --argjson available "$_gatygo_ua" --argjson run "${_gatygo_urun:-null}" \
        '{latest: (if $latest == "" then null else $latest end), available: $available, run: $run}'
}
