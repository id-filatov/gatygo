#!/bin/sh
# The router's own xray core: the archive for its architecture comes from the pinned release,
# is checked against the pinned SHA256 and only then unpacked into gatygo's own directory. The
# "release" here is the mock panel serving zips with a shell script for a binary.
. "$(dirname "$0")/../lib.sh"
tmp=$(mktemp -d)
export GATYGO_STATE="$tmp/state" GATYGO_RUN="$tmp/run" GATYGO_SYSROOT="$tmp/sysroot"
export GATYGO_CORE_DIR="$tmp/core" GATYGO_XRAY="$tmp/core/xray" GATYGO_CORE_PIN="$tmp/core.pin"
export GATYGO_CORE_BASE=http://127.0.0.1:8792/geo
mkdir -p "$GATYGO_STATE" "$GATYGO_RUN" "$GATYGO_SYSROOT/etc" "$tmp/rel"
. "$GATYGO_LIB/core.sh"

_arch() { printf "DISTRIB_RELEASE='25.12.5'\nDISTRIB_ARCH='%s'\n" "$1" > "$GATYGO_SYSROOT/etc/openwrt_release"; }
# _zip FILE MEMBER=TEXT... — a release archive whose "binaries" print TEXT for `version`
_zip() {
    python3 - "$@" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("geoip.dat", "not wanted")
    for m in sys.argv[2:]:
        name, text = m.split("=", 1)
        z.writestr(name, "#!/bin/sh\n" + text + "\n")
EOF
}
_pin() { printf '# test pin\n%s  %s\n' "$(sha256sum < "$tmp/rel/$2" | cut -d' ' -f1)" "$1/$2" > "$GATYGO_CORE_PIN"; }
_requests() { curl -fs http://127.0.0.1:8792/log | jq '[.[] | select(.path | startswith("/geo/"))] | length'; }

python3 /src/tests/mock/sub_server.py 8792 "$FIXTURES/subscription.json" "$tmp/rel" http://127.0.0.1:8792 >/dev/null 2>&1 &
_mock=$!
for _ in $(seq 1 50); do curl -fs -o /dev/null http://127.0.0.1:8792/log && break; sleep 0.1; done

# --- which archive, and which binary in it, for this router
while read -r _a _want; do
    _arch "$_a"
    assert_eq "$_want" "$(gatygo_core_asset | tr ' ' ':')" "architecture $_a"
done <<'EOF'
aarch64_generic Xray-linux-arm64-v8a.zip:xray
aarch64_cortex-a53 Xray-linux-arm64-v8a.zip:xray
x86_64 Xray-linux-64.zip:xray
i386_pentium4 Xray-linux-32.zip:xray
arm_cortex-a7_neon-vfpv4 Xray-linux-arm32-v7a.zip:xray
arm_cortex-a9_vfpv3-d16 Xray-linux-arm32-v7a.zip:xray
arm_cortex-a9 Xray-linux-arm32-v5.zip:xray
arm_arm1176jzf-s_vfp Xray-linux-arm32-v6.zip:xray
arm_arm926ej-s Xray-linux-arm32-v5.zip:xray
mipsel_24kc Xray-linux-mips32le.zip:xray_softfloat
mips_24kc Xray-linux-mips32.zip:xray_softfloat
mips64el_mips64r2 Xray-linux-mips64le.zip:xray
mips64_octeonplus Xray-linux-mips64.zip:xray
riscv64_generic Xray-linux-riscv64.zip:xray
loongarch64_generic Xray-linux-loong64.zip:xray
EOF
_arch powerpc_8548
assert_exit 1 "an architecture without a release archive" gatygo_core_asset

# --- the shipped pin: one release, a SHA256 for every archive the map can ask for
PIN="$GATYGO_LIB/core.pin"
assert_eq "12" "$(grep -c '^[0-9a-f]\{64\}  v[0-9.]*/Xray-linux-[a-z0-9-]*\.zip$' "$PIN")" "12 archives, each with its SHA256"
assert_eq "1" "$(grep -v '^#' "$PIN" | sed 's#.*  \(.*\)/.*#\1#' | sort -u | wc -l | tr -d ' ')" "all of one release"
for _a in aarch64_generic x86_64 i386_pentium4 arm_cortex-a7_neon-vfpv4 arm_cortex-a9 arm_arm1176jzf-s_vfp mipsel_24kc mips_24kc mips64el_mips64r2 mips64_octeonplus riscv64_generic loongarch64_generic; do
    _arch "$_a"
    assert_exit 0 "the shipped pin covers $_a" sh -c "GATYGO_CORE_PIN='$PIN'; . '$GATYGO_LIB/core.sh'; gatygo_core_pinned >/dev/null"
done

# --- first install: download, check, unpack only the binary
_arch aarch64_generic
_zip "$tmp/rel/Xray-linux-arm64-v8a.zip" "xray=echo 'Xray 1.0.0 (test)'"
_pin v1.0.0 Xray-linux-arm64-v8a.zip
assert_exit 1 "no core yet" gatygo_core_ready
assert_eq "installed" "$(gatygo_core_ensure 2>/dev/null)" "ensure installs the pinned core"
assert_eq "Xray 1.0.0 (test)" "$("$GATYGO_XRAY" version)" "the binary runs"
assert_eq "-rwxr-xr-x" "$(ls -l "$GATYGO_XRAY" | cut -c1-10)" "it is executable"
assert_eq "pin xray" "$(ls "$GATYGO_CORE_DIR" | sort | tr '\n' ' ' | sed 's/ $//')" "only the binary and what it was installed from (no geo files, no archive)"
assert_exit 0 "the core is ready" gatygo_core_ready
assert_eq "v1.0.0" "$(gatygo_core_version)" "the pinned release is known"

# --- nothing to do: no download
_n=$(_requests)
assert_eq "ready" "$(gatygo_core_ensure 2>/dev/null)" "ensure with the pinned core in place"
assert_eq "$_n" "$(_requests)" "no request was made"

# --- a package update pins another release: the core follows
_zip "$tmp/rel/Xray-linux-arm64-v8a.zip" "xray=echo 'Xray 2.0.0 (test)'"
_pin v2.0.0 Xray-linux-arm64-v8a.zip
assert_exit 1 "the installed core is not the pinned one" gatygo_core_ready
assert_eq "installed" "$(gatygo_core_ensure 2>/dev/null)" "ensure replaces it"
assert_eq "Xray 2.0.0 (test)" "$("$GATYGO_XRAY" version)" "the new binary runs"

# --- an archive that is not the pinned one is never unpacked; the core in place stays
_zip "$tmp/rel/Xray-linux-arm64-v8a.zip" "xray=echo 'Xray 6.6.6 (evil)'"
printf '# test pin\n%064d  v3.0.0/Xray-linux-arm64-v8a.zip\n' 0 > "$GATYGO_CORE_PIN"
_out=$(gatygo_core_ensure 2>"$tmp/err"); _rc=$?
assert_eq "kept 0" "$_out $_rc" "a wrong SHA256: the core in place is kept"
assert_eq "Xray 2.0.0 (test)" "$("$GATYGO_XRAY" version)" "and it is still the old one"
assert_exit 0 "the log says why" grep -q 'SHA256' "$tmp/err"
assert_exit 1 "nothing is left behind" sh -c "ls '$GATYGO_CORE_DIR' | grep -qv -e '^xray\$' -e '^pin\$'"

# --- without a core in place the same failures are fatal
rm -rf "$GATYGO_CORE_DIR"
_out=$(gatygo_core_ensure 2>/dev/null); _rc=$?
assert_eq " 1" "$_out $_rc" "a wrong SHA256 and no core in place: exit 1"
assert_exit 1 "no binary was installed" test -e "$GATYGO_XRAY"
rm -f "$tmp/rel/Xray-linux-arm64-v8a.zip"
_out=$(gatygo_core_ensure 2>"$tmp/err"); _rc=$?
assert_eq " 1" "$_out $_rc" "the download fails and no core in place: exit 1"
assert_exit 0 "the log says the download failed" grep -q 'download failed' "$tmp/err"

# --- a binary that does not run on this router is not installed
_zip "$tmp/rel/Xray-linux-arm64-v8a.zip" "xray=exit 126"
_pin v4.0.0 Xray-linux-arm64-v8a.zip
assert_exit 1 "a binary that does not run is refused" gatygo_core_ensure
assert_exit 1 "and not installed" test -e "$GATYGO_XRAY"

# --- MIPS routers have no FPU: the archive's soft-float binary is the one
_arch mipsel_24kc
_zip "$tmp/rel/Xray-linux-mips32le.zip" "xray=echo 'Xray hard'" "xray_softfloat=echo 'Xray soft'"
_pin v4.0.0 Xray-linux-mips32le.zip
assert_eq "installed" "$(gatygo_core_ensure 2>/dev/null)" "ensure on a MIPS router"
assert_eq "Xray soft" "$("$GATYGO_XRAY" version)" "the soft-float binary was unpacked"

# --- no archive for this router, or none pinned
rm -rf "$GATYGO_CORE_DIR"
_arch powerpc_8548
assert_exit 1 "unknown architecture: ensure fails" gatygo_core_ensure
_arch x86_64
assert_exit 1 "nothing pinned for this architecture: ensure fails" gatygo_core_ensure

# --- another binary was named: not gatygo's to manage
assert_eq "ready" "$(GATYGO_XRAY=xray gatygo_core_ensure)" "a named xray is taken as it is"

kill "$_mock" 2>/dev/null
rm -rf "$tmp"
report
