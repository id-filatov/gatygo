#!/bin/sh
# LuCI translations: po2lmo.py against LuCI's own po2lmo, lookups by cbi.js rules.
. "$(dirname "$0")/../lib.sh"
PO2LMO=/src/luci-app-gatygo/po/po2lmo.py
FX=/src/tests/fixtures/i18n
T=$(mktemp -d)

# --- po2lmo.py: byte-identical to LuCI's C po2lmo on every form it reads
assert_exit 0 "po2lmo.py compiles the fixture" python3 "$PO2LMO" "$FX/sample.po" "$T/sample.lmo"
assert_exit 0 "same bytes as LuCI's po2lmo" cmp "$FX/sample.lmo" "$T/sample.lmo"

# nothing to write (no entry, no plural formula): no file, like the C tool
printf 'msgid ""\nmsgstr "Content-Type: text/plain; charset=UTF-8\\n"\n' > "$T/empty.po"
python3 "$PO2LMO" "$T/empty.po" "$T/empty.lmo"
assert_exit 1 "an empty catalog leaves no file" test -e "$T/empty.lmo"
assert_exit 1 "a missing input is an error" python3 "$PO2LMO" "$T/nope.po" "$T/nope.lmo"

# --- lookups the way LuCI's browser side does them (cbi.js _ and N_)
_lookup() {
    python3 - "$T/sample.lmo" "$@" <<'EOF'
import struct, sys
sys.path.insert(0, '/src/luci-app-gatygo/po')
from po2lmo import sfh_hash
data = open(sys.argv[1], 'rb').read()
at = struct.unpack('>I', data[-4:])[0]
table = {}
for i in range(at, len(data) - 4, 16):
    k, _, off, ln = struct.unpack('>IIII', data[i:i + 16])
    table[k] = data[off:off + ln].decode()
key = sys.argv[2].encode().replace(b'\\1', b'\1').replace(b'\\2', b'\2')
print(table.get(sfh_hash(key) if key else 0, '<none>'))
EOF
}
assert_eq "Подключить" "$(_lookup 'Connect')" "plain string"
assert_eq "Не удалось переключиться на %s" "$(_lookup 'Couldn’t switch to %s')" "a typographic apostrophe hashes as UTF-8"
assert_eq 'Он сказал «вперёд» \ сейчас' "$(_lookup 'He said "go" \ now')" "escaped quote and backslash"
assert_eq "Длинная строка с продолжением" "$(_lookup 'A long line continued here')" "continuation lines join"
assert_eq "%d минуту назад" "$(_lookup '%d minute ago\20')" "first plural form: key msgid\\2 0"
assert_eq "%d минуты назад" "$(_lookup '%d minute ago\21')" "second plural form"
assert_eq "%d минут назад" "$(_lookup '%d minute ago\22')" "third plural form"
assert_eq "Журнал" "$(_lookup 'menu\1Log')" "context key is ctxt\\1msgid"
assert_eq "<none>" "$(_lookup 'Not translated yet')" "an empty msgstr is not written"
assert_eq "<none>" "$(_lookup 'VPN')" "a msgstr equal to its msgid is not written"
assert_eq "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);" "$(_lookup '')" "the plural formula is entry 0"

# --- i18n-scan.py: the template, the sync of the .po files, and --check
SCAN="python3 /src/tools/i18n-scan.py --js-dir $FX/js"
P=$T/po
mkdir -p "$P/ru"
sed -n '1,/^$/p' "$FX/ru-complete.po" > "$P/ru/gatygo.po"   # the header only
assert_exit 0 "scan writes the template" $SCAN --po-dir "$P"
assert_exit 0 "template as expected" cmp "$FX/expected.pot" "$P/templates/gatygo.pot"
assert_eq 3 "$(grep -c '^msgstr\[' "$P/ru/gatygo.po")" "the ru sync gives a plural all three forms"
assert_eq 4 "$(grep -c '^msgid "[^"]' "$P/ru/gatygo.po")" "the ru sync lists every string once"
_err=$($SCAN --po-dir "$P" --check 2>&1); assert_eq 1 "$?" "--check fails on untranslated strings"
case $_err in *"empty translation"*) _t_ok ;; *) _t_bad "--check names the empty translations: $_err" ;; esac

cp "$FX/ru-complete.po" "$P/ru/gatygo.po"
assert_exit 0 "--check passes a complete, current tree" $SCAN --po-dir "$P" --check

sed 's/"Обновлено %s."/"Обновлено."/' "$FX/ru-complete.po" > "$P/ru/gatygo.po"
_err=$($SCAN --po-dir "$P" --check 2>&1); assert_eq 1 "$?" "a lost placeholder fails --check"
case $_err in *placeholders*) _t_ok ;; *) _t_bad "--check names the placeholder mismatch: $_err" ;; esac

{ cat "$FX/ru-complete.po"; printf '\nmsgid "Gone"\nmsgstr "Ушло"\n'; } > "$P/ru/gatygo.po"
_err=$($SCAN --po-dir "$P" --check 2>&1); assert_eq 1 "$?" "an obsolete translation fails --check"
case $_err in *obsolete*) _t_ok ;; *) _t_bad "--check names the obsolete string: $_err" ;; esac
$SCAN --po-dir "$P" >/dev/null 2>&1
assert_exit 0 "a plain run drops it and keeps the rest" cmp "$FX/ru-complete.po" "$P/ru/gatygo.po"

J=$T/js; mkdir -p "$J"
cp "$FX/js/view.js" "$J/"; echo "var h = _('Brand new');" >> "$J/view.js"
_err=$(python3 /src/tools/i18n-scan.py --js-dir "$J" --po-dir "$P" --check 2>&1); assert_eq 1 "$?" "a new string makes the template stale"
case $_err in *stale*) _t_ok ;; *) _t_bad "--check says the template is stale: $_err" ;; esac

echo "var i = _('two  spaces');" > "$J/view.js"
_err=$(python3 /src/tools/i18n-scan.py --js-dir "$J" --po-dir "$P" --check 2>&1); assert_eq 1 "$?" "a doubled space is refused"
case $_err in *whitespace*) _t_ok ;; *) _t_bad "the scanner names the whitespace: $_err" ;; esac

echo "var j = _(label);" > "$J/view.js"
_err=$(python3 /src/tools/i18n-scan.py --js-dir "$J" --po-dir "$P" --check 2>&1); assert_eq 1 "$?" "a non-literal _() is refused"
case $_err in *literal*) _t_ok ;; *) _t_bad "the scanner names the non-literal call: $_err" ;; esac

rm -rf "$T"
report
