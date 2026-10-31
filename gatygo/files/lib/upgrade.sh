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

# --- the progress of an upgrade: $GATYGO_RUN/upgrade.json
# {"state":"running"|"ok"|"failed","from":…,"to":…,"time":<epoch of the last change>,
#  "steps":{"check":S,"download":S,"install":S,"core":S,"restart":S},"code":…,"args":[…],
#  "rolled_back":…}, S one of todo now ok skip warn fail. The executor of the old version writes
# it, the pages of the old and of the new version read it: fields are added, never renamed.

# _gatygo_upgrade_edit FILTER [JQ_ARG…] — apply FILTER to the progress file, stamp the time
_gatygo_upgrade_edit() {
    _gatygo_uj=$GATYGO_RUN/upgrade.json
    _gatygo_uflt=$1; shift
    jq -c "$@" --argjson now "$(date +%s)" "$_gatygo_uflt | .time = \$now" "$_gatygo_uj" > "$_gatygo_uj.tmp" \
        && mv "$_gatygo_uj.tmp" "$_gatygo_uj"
}

# gatygo_upgrade_begin FROM TO — a new run: every step waits, the check is under way
gatygo_upgrade_begin() {
    mkdir -p "$GATYGO_RUN"
    jq -nc --arg from "$1" --arg to "$2" --argjson now "$(date +%s)" \
        '{state: "running", from: $from, to: $to, time: $now,
          steps: {check: "now", download: "todo", install: "todo", core: "todo", restart: "todo"},
          code: "", args: [], rolled_back: false}' > "$GATYGO_RUN/upgrade.json.tmp" \
        && mv "$GATYGO_RUN/upgrade.json.tmp" "$GATYGO_RUN/upgrade.json"
}

# gatygo_upgrade_set_to V — the version the run goes to (the check found a fresher one)
gatygo_upgrade_set_to() {
    _gatygo_upgrade_edit '.to = $v' --arg v "$1"
}

# gatygo_upgrade_mark STEP S — one step's mark; after ok, skip or warn the next step is under way
gatygo_upgrade_mark() {
    _gatygo_upgrade_edit '.steps[$s] = $v
        | ({check: "download", download: "install", install: "core", core: "restart"}[$s]) as $n
        | if $n != null and ($v == "ok" or $v == "skip" or $v == "warn") then .steps[$n] = "now" else . end' \
        --arg s "$1" --arg v "$2"
}

# gatygo_upgrade_fail CODE [ARG…] — the run failed at the step under way. CODE names the cause
# for the page (it picks the wording), ARGs fill it in.
gatygo_upgrade_fail() {
    _gatygo_uc=$1; shift
    _gatygo_upgrade_edit '.state = "failed" | .code = $c | .args = $a
        | .steps |= map_values(if . == "now" then "fail" else . end)' \
        --arg c "$_gatygo_uc" --argjson a "$(jq -nc '$ARGS.positional' --args "$@")"
    gatygo_log error "upgrade: failed: $_gatygo_uc${*:+ ($*)}"
}

# gatygo_upgrade_finish — the run is over and the new version works
gatygo_upgrade_finish() {
    _gatygo_upgrade_edit '.state = "ok"'
    gatygo_log info "upgrade: gatygo $(jq -r .to "$GATYGO_RUN/upgrade.json") is installed"
}

# gatygo_upgrade_free_kb PATH — free kilobytes on the file system of PATH
gatygo_upgrade_free_kb() {
    df -k "$1" 2>/dev/null | awk 'END { print $(NF - 2) }'
}

# _gatygo_upgrade_get URL FILE — one download, quiet; exit as curl
_gatygo_upgrade_get() {
    curl -fsSL --proto '=http,https' --connect-timeout 15 --max-time "${3:-60}" -o "$2" "$1" 2>/dev/null
}

# gatygo_upgrade_preflight WORK — the check step: everything that would stop the upgrade, before
# anything on the router changes. Takes the update lock and leaves it to the caller. Sets
# _gatygo_up_new (the version) and _gatygo_up_core (1 when the new version pins another core).
# The first refusal fails the run, exit 1.
gatygo_upgrade_preflight() {
    _gatygo_uw=$1
    gatygo_update_lock || { gatygo_upgrade_fail busy; return 1; }
    _gatygo_upgrade_get "$(gatygo_upgrade_api)/latest" "$_gatygo_uw/release.json" \
        && gatygo_upgrade_release "$_gatygo_uw/release.json" > "$_gatygo_uw/new.json" \
        && _gatygo_up_new=$(jq -r .version "$_gatygo_uw/new.json") \
        && gatygo_upgrade_newer "$_gatygo_up_new" "$GATYGO_VERSION" || { gatygo_upgrade_fail no_release; return 1; }
    gatygo_upgrade_set_to "$_gatygo_up_new"
    # the installed version's packages: what a failed upgrade goes back to
    _gatygo_upgrade_get "$(gatygo_upgrade_api)/tags/v$GATYGO_VERSION" "$_gatygo_uw/release.json" \
        && gatygo_upgrade_release "$_gatygo_uw/release.json" > "$_gatygo_uw/old.json" \
        || { gatygo_upgrade_fail no_rollback; return 1; }
    _gatygo_ur=$(gatygo_os_version)
    case $_gatygo_ur in 25.12*) ;; *) gatygo_upgrade_fail openwrt "${_gatygo_ur:-unknown}"; return 1 ;; esac
    for _gatygo_up in $GATYGO_UPGRADE_CONFLICTS; do
        apk info -e "$_gatygo_up" >/dev/null 2>&1 && { gatygo_upgrade_fail conflict "$_gatygo_up"; return 1; }
    done
    _gatygo_upgrade_get "$(gatygo_upgrade_raw)/v$_gatygo_up_new/gatygo/files/lib/core.pin" "$_gatygo_uw/core.pin"
    # in a subshell: an assignment in front of a function call does not reliably stay local in ash
    _gatygo_upin=$(GATYGO_CORE_PIN=$_gatygo_uw/core.pin; gatygo_core_pinned) || { gatygo_upgrade_fail no_core; return 1; }
    _gatygo_up_core=0
    [ "$_gatygo_upin" = "$(cat "$GATYGO_CORE_DIR/pin" 2>/dev/null)" ] || _gatygo_up_core=1
    # flash: the packages and, for another core, room for its 35 MB binary next to the old one
    _gatygo_uneed=2048
    [ "$_gatygo_up_core" = 1 ] && _gatygo_uneed=40960
    _gatygo_ud=/overlay
    [ -d "$_gatygo_ud" ] || _gatygo_ud=/
    _gatygo_ufree=$(gatygo_upgrade_free_kb "$_gatygo_ud")
    [ "${_gatygo_ufree:-0}" -ge "$_gatygo_uneed" ] 2>/dev/null \
        || { gatygo_upgrade_fail no_space $((_gatygo_uneed / 1024)) $((${_gatygo_ufree:-0} / 1024)); return 1; }
    # memory: the downloads, the copy of the state dir, the core's archive
    _gatygo_uneed=$(du -sk "$GATYGO_STATE" 2>/dev/null | cut -f1)
    _gatygo_uneed=$((${_gatygo_uneed:-0} + 5120))
    [ "$_gatygo_up_core" = 1 ] && _gatygo_uneed=$((_gatygo_uneed + 25600))
    _gatygo_ufree=$(gatygo_upgrade_free_kb /tmp)
    [ "${_gatygo_ufree:-0}" -ge "$_gatygo_uneed" ] 2>/dev/null \
        || { gatygo_upgrade_fail no_memory $((_gatygo_uneed / 1024)) $((${_gatygo_ufree:-0} / 1024)); return 1; }
    gatygo_upgrade_mark check ok
}

# gatygo_upgrade_download WORK — the download step: both packages of the new version to
# WORK/new, of the installed one to WORK/old, each checked against GitHub's SHA256 when it gives
# one; then apk resolves the new packages against the router's feeds without installing them.
gatygo_upgrade_download() {
    _gatygo_uw=$1
    mkdir -p "$_gatygo_uw/new" "$_gatygo_uw/old"
    for _gatygo_ud in new old; do
        for _gatygo_up in gatygo luci; do
            _gatygo_uf=$_gatygo_uw/$_gatygo_ud/gatygo.apk
            [ "$_gatygo_up" = luci ] && _gatygo_uf=$_gatygo_uw/$_gatygo_ud/luci-app-gatygo.apk
            _gatygo_upgrade_get "$(jq -r ".$_gatygo_up.url" "$_gatygo_uw/$_gatygo_ud.json")" "$_gatygo_uf" 120 \
                || { gatygo_upgrade_fail download_failed; return 1; }
            _gatygo_us=$(jq -r ".$_gatygo_up.sha256" "$_gatygo_uw/$_gatygo_ud.json")
            [ -z "$_gatygo_us" ] || [ "$(sha256sum < "$_gatygo_uf" | cut -d' ' -f1)" = "$_gatygo_us" ] \
                || { gatygo_upgrade_fail checksum; return 1; }
        done
    done
    _gatygo_uo=$(apk add --simulate --allow-untrusted "$_gatygo_uw/new/gatygo.apk" "$_gatygo_uw/new/luci-app-gatygo.apk" 2>&1) || {
        _gatygo_um=$(printf '%s\n' "$_gatygo_uo" | sed -n 's/^ *\([^ ][^ ]*\) (no such package):.*$/\1/p' | tr '\n' ' ')
        gatygo_upgrade_fail deps "${_gatygo_um% }"
        return 1
    }
    gatygo_upgrade_mark download ok
}
