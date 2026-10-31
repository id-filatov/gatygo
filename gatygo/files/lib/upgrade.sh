#!/bin/sh
# Upgrading gatygo itself from the LuCI page: the router learns about a newer GitHub release
# (releases/latest, at most once a day) and the page offers it next to the version number.

. "${GATYGO_LIB:-/usr/lib/gatygo}/config.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/service.sh"
. "${GATYGO_LIB:-/usr/lib/gatygo}/core.sh"

# the packages that own the same proxy rules: CONFLICTS in install.sh
GATYGO_UPGRADE_CONFLICTS="luci-app-passwall luci-app-passwall2 luci-app-openclash luci-app-homeproxy"
# the installed gatygo: after the install step these are the new version's (the executor itself
# runs from a copy of the old library). The executor's environment reaches the new version's
# processes (apk's postinst, the new CLI): config.sh exports the paths, and every version reads
# them as ${VAR:-default}. Those defaults are a contract between versions, as upgrade.json is.
GATYGO_BIN=${GATYGO_BIN:-/usr/bin/gatygo}
GATYGO_INIT=${GATYGO_INIT:-/etc/init.d/gatygo}
GATYGO_UPGRADE_TARGET=${GATYGO_UPGRADE_TARGET:-/usr/lib/gatygo}
# seconds xray has to keep one pid after the restart
GATYGO_UPGRADE_SETTLE=${GATYGO_UPGRADE_SETTLE:-10}
# where the executor works: the library copy, the downloads, the copy of the state dir
GATYGO_UPGRADE_TMP=${GATYGO_UPGRADE_TMP:-/tmp}

# _gatygo_upgrade_env — `env` arguments for a process of the installed version (apk's postinst
# scripts, the new CLI and init script): the executor's library copy goes, and so does every path
# that is only this version's default, so that the installed version takes its own. A path set
# on purpose stays.
_gatygo_upgrade_env() {
    echo -u GATYGO_LIB
    [ "$GATYGO_STATE" = /etc/gatygo ] && echo -u GATYGO_STATE
    [ "$GATYGO_RUN" = /var/run/gatygo ] && echo -u GATYGO_RUN
    [ "$GATYGO_ASSETS" = /usr/share/xray ] && echo -u GATYGO_ASSETS
    [ "$GATYGO_CORE_DIR" = /usr/lib/gatygo/core ] && echo -u GATYGO_CORE_DIR
    [ "$GATYGO_XRAY" = /usr/lib/gatygo/core/xray ] && echo -u GATYGO_XRAY
    [ -z "$GATYGO_SYSROOT" ] && echo -u GATYGO_SYSROOT
    return 0
}

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
    (umask 077; mkdir -p "$GATYGO_STATE")
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
    # running, but nobody holds the lock: the executor was killed. A failure the page can close.
    case $_gatygo_urun in
        *'"state":"running"'*) gatygo_locked upgrade || _gatygo_urun=$(printf '%s' "$_gatygo_urun" | jq -c '.state = "failed"
            | .code = "interrupted" | .args = [] | .steps |= map_values(if . == "now" then "fail" else . end)') ;;
    esac
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

# _gatygo_upgrade_kb VALUE — VALUE when it is a whole number, 0 otherwise (shell arithmetic on
# anything else would end the run)
_gatygo_upgrade_kb() {
    case $1 in '' | *[!0-9]*) echo 0 ;; *) echo "$1" ;; esac
}

# _gatygo_upgrade_get URL FILE — one download, quiet; exit as curl
_gatygo_upgrade_get() {
    curl -fsSL --proto '=http,https' --connect-timeout 15 --max-time "${3:-60}" -o "$2" "$1" 2>/dev/null
}

# _gatygo_upgrade_fetch URL FILE CODE — one download of the checks. Not there (an HTTP error):
# fail with CODE; no answer at all: fail with no_answer (the router's internet, not the release)
_gatygo_upgrade_fetch() {
    _gatygo_upgrade_get "$1" "$2" && return 0
    case $? in 22) gatygo_upgrade_fail "$3" ;; *) gatygo_upgrade_fail no_answer ;; esac
    return 1
}

# gatygo_upgrade_preflight WORK — the check step: everything that would stop the upgrade, before
# anything on the router changes. Takes the update lock and leaves it to the caller. Sets
# _gatygo_up_new (the version) and _gatygo_up_core (1 when the new version pins another core).
# The first refusal fails the run, exit 1.
gatygo_upgrade_preflight() {
    _gatygo_uw=$1
    gatygo_update_lock || { gatygo_upgrade_fail busy; return 1; }
    _gatygo_upgrade_fetch "$(gatygo_upgrade_api)/latest" "$_gatygo_uw/release.json" no_release || return 1
    gatygo_upgrade_release "$_gatygo_uw/release.json" > "$_gatygo_uw/new.json" \
        && _gatygo_up_new=$(jq -r .version "$_gatygo_uw/new.json") \
        && gatygo_upgrade_newer "$_gatygo_up_new" "$GATYGO_VERSION" || { gatygo_upgrade_fail no_release; return 1; }
    gatygo_upgrade_set_to "$_gatygo_up_new"
    # the installed version's packages: what a failed upgrade goes back to
    _gatygo_upgrade_fetch "$(gatygo_upgrade_api)/tags/v$GATYGO_VERSION" "$_gatygo_uw/release.json" no_rollback || return 1
    gatygo_upgrade_release "$_gatygo_uw/release.json" > "$_gatygo_uw/old.json" \
        || { gatygo_upgrade_fail no_rollback; return 1; }
    _gatygo_ur=$(gatygo_os_version)
    case $_gatygo_ur in 25.12*) ;; *) gatygo_upgrade_fail openwrt "${_gatygo_ur:-unknown}"; return 1 ;; esac
    for _gatygo_up in $GATYGO_UPGRADE_CONFLICTS; do
        apk info -e "$_gatygo_up" >/dev/null 2>&1 && { gatygo_upgrade_fail conflict "$_gatygo_up"; return 1; }
    done
    _gatygo_upgrade_fetch "$(gatygo_upgrade_raw)/v$_gatygo_up_new/gatygo/files/lib/core.pin" "$_gatygo_uw/core.pin" no_core || return 1
    # in a subshell: an assignment in front of a function call does not reliably stay local in ash
    _gatygo_upin=$(GATYGO_CORE_PIN=$_gatygo_uw/core.pin; gatygo_core_pinned) || { gatygo_upgrade_fail no_core; return 1; }
    _gatygo_up_core=0
    [ "$_gatygo_upin" = "$(cat "$GATYGO_CORE_DIR/pin" 2>/dev/null)" ] || _gatygo_up_core=1
    # flash: the packages and, for another core, room for its 35 MB binary next to the old one
    _gatygo_uneed=2048
    [ "$_gatygo_up_core" = 1 ] && _gatygo_uneed=40960
    _gatygo_ud=/overlay
    [ -d "$_gatygo_ud" ] || _gatygo_ud=/
    _gatygo_ufree=$(_gatygo_upgrade_kb "$(gatygo_upgrade_free_kb "$_gatygo_ud")")
    [ "$_gatygo_ufree" -ge "$_gatygo_uneed" ] \
        || { gatygo_upgrade_fail no_space $((_gatygo_uneed / 1024)) $((_gatygo_ufree / 1024)); return 1; }
    # memory: the downloads, the copy of the state dir, the core's archive
    _gatygo_uneed=$(_gatygo_upgrade_kb "$(du -sk "$GATYGO_STATE" 2>/dev/null | cut -f1)")
    _gatygo_uneed=$((_gatygo_uneed + 5120))
    [ "$_gatygo_up_core" = 1 ] && _gatygo_uneed=$((_gatygo_uneed + 25600))
    _gatygo_ufree=$(_gatygo_upgrade_kb "$(gatygo_upgrade_free_kb /tmp)")
    [ "$_gatygo_ufree" -ge "$_gatygo_uneed" ] \
        || { gatygo_upgrade_fail no_memory $((_gatygo_uneed / 1024)) $((_gatygo_ufree / 1024)); return 1; }
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
    # the feeds' index lives in tmpfs: after a reboot apk knows no package of the feeds
    apk --wait 60 update >/dev/null 2>&1
    _gatygo_uo=$(apk --wait 60 add --simulate --allow-untrusted "$_gatygo_uw/new/gatygo.apk" "$_gatygo_uw/new/luci-app-gatygo.apk" 2>&1) || {
        _gatygo_um=$(printf '%s\n' "$_gatygo_uo" | sed -n 's/^ *\([^ ][^ ]*\) (no such package):.*$/\1/p' | tr '\n' ' ')
        gatygo_upgrade_fail deps "${_gatygo_um% }"
        return 1
    }
    gatygo_upgrade_mark download ok
}

# gatygo_upgrade_install WORK — the install step. Before apk: a copy of the state dir to
# WORK/state and a hard link to the core in place (no room taken; the core step may replace the
# file). Sets _gatygo_up_running (1 when the VPN runs). A failure before apk leaves the router as
# it was; a failed apk is rolled back.
gatygo_upgrade_install() {
    _gatygo_uw=$1
    _gatygo_up_running=0
    gatygo_xray_running && _gatygo_up_running=1
    rm -rf "$_gatygo_uw/state" "$GATYGO_CORE_DIR.prev"
    if ! { (umask 077; mkdir -p "$GATYGO_STATE") && cp -a "$GATYGO_STATE" "$_gatygo_uw/state"; } \
        || { [ -f "$GATYGO_CORE_DIR/xray" ] && ! { mkdir -p "$GATYGO_CORE_DIR.prev" \
            && ln -f "$GATYGO_CORE_DIR/xray" "$GATYGO_CORE_DIR.prev/xray" \
            && { [ ! -f "$GATYGO_CORE_DIR/pin" ] || cp -p "$GATYGO_CORE_DIR/pin" "$GATYGO_CORE_DIR.prev/pin"; }; }; }; then
        rm -rf "$GATYGO_CORE_DIR.prev"
        gatygo_upgrade_fail install_failed
        return 1
    fi
    _gatygo_uo=$(env $(_gatygo_upgrade_env) apk --wait 60 add --allow-untrusted "$_gatygo_uw/new/gatygo.apk" "$_gatygo_uw/new/luci-app-gatygo.apk" 2>&1) || {
        gatygo_log error "upgrade: apk: $(printf '%s' "$_gatygo_uo" | tail -n 3 | tr '\n' ' ')"
        _gatygo_upgrade_abort "$_gatygo_uw" install_failed
        return 1
    }
    gatygo_upgrade_mark install ok
}

# gatygo_upgrade_core WORK — the core step, by the new version's core.sh: the core it pins.
# Not downloaded (kept) is a warning: the core in place still runs.
gatygo_upgrade_core() {
    _gatygo_uo=$(env $(_gatygo_upgrade_env) GATYGO_LIB="$GATYGO_UPGRADE_TARGET" sh -c '. "$GATYGO_LIB/core.sh"; gatygo_core_ensure' 2>/dev/null) || {
        _gatygo_upgrade_abort "$1" core_failed
        return 1
    }
    case $_gatygo_uo in
        *ready) gatygo_upgrade_mark core skip ;;
        *kept) gatygo_upgrade_mark core warn ;;
        *) gatygo_upgrade_mark core ok ;;
    esac
}

# _gatygo_upgrade_steady — xray runs within 30 s and keeps one pid for GATYGO_UPGRADE_SETTLE
# seconds; procd may still be restarting it for a new core, hence up to three such windows
_gatygo_upgrade_steady() {
    _gatygo_ui=0
    until gatygo_xray_running; do
        [ "$_gatygo_ui" -lt 30 ] || return 1
        _gatygo_ui=$((_gatygo_ui + 1))
        sleep 1
    done
    _gatygo_ui=0
    while [ "$_gatygo_ui" -lt 3 ]; do
        _gatygo_ui=$((_gatygo_ui + 1))
        _gatygo_upid=$(gatygo_xray_pid)
        sleep "$GATYGO_UPGRADE_SETTLE"
        [ -n "$_gatygo_upid" ] && [ "$(gatygo_xray_pid)" = "$_gatygo_upid" ] && gatygo_xray_running && return 0
    done
    return 1
}

# gatygo_upgrade_restart WORK — the last step: the new version builds the config from the cached
# subscription (`gatygo apply`, it takes the update lock itself) and, when the VPN ran, starts
# again (procd restarts xray only for a changed config or core). A VPN that was stopped stays
# stopped; the new version answering is the check then.
gatygo_upgrade_restart() {
    _gatygo_uw=$1
    gatygo_update_unlock
    # nothing cached to build from (a link whose subscription never came): nothing to rebuild
    _gatygo_uarc=0 _gatygo_ui=0
    while [ -s "$GATYGO_STATE/subscription.json" ]; do
        env $(_gatygo_upgrade_env) GATYGO_LIB="$GATYGO_UPGRADE_TARGET" GATYGO_UPGRADE_RUN=1 "$GATYGO_BIN" apply wait >/dev/null 2>&1
        _gatygo_uarc=$?
        # 2: an update held the lock for the whole minute `apply wait` waits; it ends, wait again
        [ "$_gatygo_uarc" = 2 ] && [ "$_gatygo_ui" -lt 3 ] || break
        _gatygo_ui=$((_gatygo_ui + 1))
    done
    case $_gatygo_uarc in
        0) ;;
        1) _gatygo_upgrade_abort "$_gatygo_uw" config_failed; return 1 ;;
        *) _gatygo_upgrade_abort "$_gatygo_uw" not_started; return 1 ;;
    esac
    if [ "$_gatygo_up_running" = 1 ]; then
        env $(_gatygo_upgrade_env) "$GATYGO_INIT" start >/dev/null 2>&1
        _gatygo_upgrade_steady || { _gatygo_upgrade_abort "$_gatygo_uw" not_started; return 1; }
    else
        [ "$(env $(_gatygo_upgrade_env) GATYGO_LIB="$GATYGO_UPGRADE_TARGET" "$GATYGO_BIN" version 2>/dev/null)" = "$_gatygo_up_new" ] \
            || { _gatygo_upgrade_abort "$_gatygo_uw" not_started; return 1; }
    fi
    gatygo_upgrade_mark restart ok
}

# gatygo_upgrade_rollback WORK — the router as before the upgrade: the new version stopped (when
# the VPN ran: its firewall and DNS go with it), the state dir and the core (with its pin) from
# what the install step kept, then the installed version's packages, then xray again when it ran.
# Exit 1 when any of it fails; packages apk would not touch at all (another apk holds its
# database) are no failure when the old version is still the one installed.
gatygo_upgrade_rollback() {
    _gatygo_uw=$1 _gatygo_uok=0
    gatygo_log warn "upgrade: putting gatygo $GATYGO_VERSION back"
    # the update lock again (the rebuild let it go): no update writes the state dir meanwhile
    if [ "$(cat "$GATYGO_RUN/update.lock/pid" 2>/dev/null)" != "$$" ]; then
        _gatygo_ui=0
        until gatygo_update_lock || [ "$_gatygo_ui" -ge 300 ]; do
            _gatygo_ui=$((_gatygo_ui + 1))
            sleep 1
        done
    fi
    [ "$_gatygo_up_running" = 1 ] && env $(_gatygo_upgrade_env) "$GATYGO_INIT" stop >/dev/null 2>&1
    # the one guard between an empty or relative path and `rm -rf /*` (as in forget.sh)
    case $GATYGO_STATE in /?*) ;; *) _gatygo_uok=1 ;; esac
    if [ "$_gatygo_uok" = 0 ] && [ -d "$_gatygo_uw/state" ]; then
        rm -rf "$GATYGO_STATE"/* "$GATYGO_STATE"/.[!.]* && cp -a "$_gatygo_uw/state/." "$GATYGO_STATE/" || _gatygo_uok=1
    fi
    if [ -f "$GATYGO_CORE_DIR.prev/xray" ]; then
        mkdir -p "$GATYGO_CORE_DIR" && mv -f "$GATYGO_CORE_DIR.prev/xray" "$GATYGO_CORE_DIR/xray" || _gatygo_uok=1
        [ ! -f "$GATYGO_CORE_DIR.prev/pin" ] || mv -f "$GATYGO_CORE_DIR.prev/pin" "$GATYGO_CORE_DIR/pin" || _gatygo_uok=1
    fi
    # a link to the very file in place is not moved (rename does nothing): it goes here
    rm -rf "$GATYGO_CORE_DIR.prev"
    env $(_gatygo_upgrade_env) apk --wait 60 add --allow-untrusted "$_gatygo_uw/old/gatygo.apk" "$_gatygo_uw/old/luci-app-gatygo.apk" >/dev/null 2>&1 \
        || [ "$(cat "$GATYGO_UPGRADE_TARGET/version" 2>/dev/null)" = "$GATYGO_VERSION" ] || _gatygo_uok=1
    if [ "$_gatygo_up_running" = 1 ]; then
        env $(_gatygo_upgrade_env) "$GATYGO_INIT" start >/dev/null 2>&1
        _gatygo_ui=0
        until gatygo_xray_running; do
            [ "$_gatygo_ui" -lt 30 ] || { _gatygo_uok=1; break; }
            _gatygo_ui=$((_gatygo_ui + 1))
            sleep 1
        done
    fi
    [ "$_gatygo_uok" = 0 ] && _gatygo_upgrade_edit '.rolled_back = true'
    return $_gatygo_uok
}

# _gatygo_upgrade_abort WORK CODE [ARG…] — roll back, then fail the run: the page shows the
# failure once the installed version works again (rollback_failed when it does not)
_gatygo_upgrade_abort() {
    _gatygo_uw=$1; shift
    if gatygo_upgrade_rollback "$_gatygo_uw"; then
        gatygo_upgrade_fail "$@"
    else
        gatygo_log error "upgrade: failed: $1${2:+ (${*#* })}; the previous version could not be put back"
        gatygo_upgrade_fail rollback_failed
    fi
}

# gatygo_upgrade_run — the whole upgrade, one at a time (another one running: exit 0, its
# progress file stays). Every step marks its outcome in $GATYGO_RUN/upgrade.json.
gatygo_upgrade_run() {
    gatygo_lock upgrade || return 0
    # started from a shell that may go away (ssh): a hangup must not cut the upgrade off
    trap '' HUP
    _gatygo_uwork=$(mktemp -d "$GATYGO_UPGRADE_TMP/gatygo-upgrade.XXXXXX" 2>/dev/null) || {
        gatygo_upgrade_begin "$GATYGO_VERSION" ""
        gatygo_upgrade_fail no_memory 1 $(($(_gatygo_upgrade_kb "$(gatygo_upgrade_free_kb "$GATYGO_UPGRADE_TMP")") / 1024))
        gatygo_unlock upgrade
        return 1
    }
    gatygo_upgrade_begin "$GATYGO_VERSION" "$(jq -r '.version // empty' "$GATYGO_STATE/upgrade-latest.json" 2>/dev/null)"
    _gatygo_urc=1
    if gatygo_upgrade_preflight "$_gatygo_uwork" && gatygo_upgrade_download "$_gatygo_uwork" \
        && gatygo_upgrade_install "$_gatygo_uwork" && gatygo_upgrade_core "$_gatygo_uwork" \
        && gatygo_upgrade_restart "$_gatygo_uwork"; then
        rm -rf "$GATYGO_CORE_DIR.prev"
        gatygo_upgrade_finish
        _gatygo_urc=0
    fi
    # the update lock, when it is still ours (`gatygo apply` and cron take it after the install)
    [ "$(cat "$GATYGO_RUN/update.lock/pid" 2>/dev/null)" = "$$" ] && gatygo_update_unlock
    rm -rf "$_gatygo_uwork"
    gatygo_unlock upgrade
    # an update asked for while the packages installed (cron, a start): the installed version runs it
    if [ -e "$GATYGO_RUN/update-wanted" ]; then
        rm -f "$GATYGO_RUN/update-wanted"
        (env $(_gatygo_upgrade_env) "$GATYGO_BIN" update </dev/null >/dev/null 2>&1 &)
    fi
    return $_gatygo_urc
}
