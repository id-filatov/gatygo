#!/usr/bin/env python3
"""Keep the LuCI translations of gatygo in step with the page scripts.

  tools/i18n-scan.py          rewrite po/templates/gatygo.pot from the JS and bring every
                              po/<lang>/gatygo.po in line with it: new strings get an empty
                              translation, strings the JS no longer has are dropped
  tools/i18n-scan.py --check  change nothing; list the problems and exit 1 when the template is
                              stale, a string is not canonical, or a translation is missing,
                              empty, obsolete or has other placeholders than the English

--js-dir and --po-dir point at another tree (the unit tests use them).
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CALL = re.compile(r'(?<![\w$.])(N_|_)\(')
PLACEHOLDER = re.compile(r'%(?:\d+\$)?[-+ 0#]*(?:\d+|\*)?(?:\.\d+)?[a-zA-Z%]')
NPLURALS = re.compile(r'nplurals\s*=\s*(\d+)')
JS_ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '0': '\0'}
POT_HEADER = 'Content-Type: text/plain; charset=UTF-8\n'


class ScanError(Exception):
    pass


def _skip_space(src, i):
    while i < len(src) and src[i].isspace():
        i += 1
    return i


def js_literal(src, i):
    """The JS string literal at src[i] (leading whitespace allowed): (text, index after it)."""
    i = _skip_space(src, i)
    if i >= len(src) or src[i] not in '\'"':
        raise ScanError('not a plain string literal')
    quote, i, out = src[i], i + 1, []
    while i < len(src) and src[i] != '\n':
        c = src[i]
        if c == quote:
            return ''.join(out), i + 1
        if c == '\\':
            n = src[i + 1]
            if n == 'u':
                out.append(chr(int(src[i + 2:i + 6], 16)))
                i += 6
            elif n == 'x':
                out.append(chr(int(src[i + 2:i + 4], 16)))
                i += 4
            else:
                out.append(JS_ESCAPES.get(n, n))
                i += 2
            continue
        out.append(c)
        i += 1
    raise ScanError('unterminated string literal')


def _expect(src, i, ch):
    i = _skip_space(src, i)
    if i >= len(src) or src[i] != ch:
        raise ScanError(f"expected '{ch}': only plain string literals are translated")
    return i + 1


def _skip_argument(src, i):
    """Index just after the ',' that ends the expression starting at src[i]."""
    depth = 0
    while i < len(src):
        c = src[i]
        if c in '\'"':
            _, i = js_literal(src, i)
            continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth < 0:
                break
        elif c == ',' and depth == 0:
            return i + 1
        i += 1
    raise ScanError('N_() needs a count and two string literals')


def canonical(s):
    """The form LuCI looks a string up by (cbi.js trimws)."""
    return re.sub(r'[ \t\n]+', ' ', s.strip())


def scan(js_dir):
    """{(msgid, msgid_plural or None): [file, ...]} in order of first appearance."""
    paths = []
    for dirpath, dirnames, files in os.walk(js_dir):
        dirnames.sort()
        paths += [os.path.join(dirpath, f) for f in sorted(files) if f.endswith('.js')]
    entries, errors = {}, []
    for path in paths:
        with open(path, encoding='utf-8') as fh:
            src = fh.read()
        ref = os.path.relpath(path, ROOT)
        for m in CALL.finditer(src):
            where = f'{ref}:{src.count(chr(10), 0, m.start()) + 1}'
            try:
                if m.group(1) == '_':
                    msgid, i = js_literal(src, m.end())
                    plural = None
                else:
                    i = _skip_argument(src, m.end())
                    msgid, i = js_literal(src, i)
                    plural, i = js_literal(src, _expect(src, i, ','))
                _expect(src, i, ')')
            except ScanError as e:
                errors.append(f'{where}: {m.group(1)}(): {e}')
                continue
            for s in (msgid, plural):
                if s is not None and s != canonical(s):
                    errors.append(f'{where}: extra whitespace in {s!r}: LuCI looks up {canonical(s)!r}')
            refs = entries.setdefault((msgid, plural), [])
            if ref not in refs:
                refs.append(ref)
    if errors:
        raise ScanError('\n'.join(errors))
    return entries


def _po_quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t') + '"'


def _po_unquote(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            out.append({'n': '\n', 't': '\t'}.get(s[i + 1], s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)


def parse_po(text):
    """(header, {(msgid, msgid_plural or None): {form: msgstr}}) of a .po file."""
    header, entries, cur, field = None, {}, None, None

    def done():
        nonlocal header
        if cur is None:
            return
        if cur['id'] == '' and cur['plural'] is None:
            header = cur['strs'].get(0, '')
        else:
            entries[(cur['id'], cur['plural'])] = cur['strs']

    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        m = re.match(r'(msgctxt|msgid_plural|msgid|msgstr(?:\[(\d+)\])?)\s+"(.*)"$', line)
        if m:
            kw, s = m.group(1), _po_unquote(m.group(3))
            if kw == 'msgctxt':
                raise ValueError('msgctxt is not used by gatygo')
            if kw == 'msgid':
                done()
                cur, field = {'id': s, 'plural': None, 'strs': {}}, 'id'
            elif kw == 'msgid_plural':
                cur['plural'], field = s, 'plural'
            else:
                field = int(m.group(2) or 0)
                cur['strs'][field] = s
            continue
        m = re.match(r'"(.*)"$', line)
        if m and cur is not None:
            s = _po_unquote(m.group(1))
            if isinstance(field, int):
                cur['strs'][field] += s
            else:
                cur[field] += s
            continue
        raise ValueError(f'cannot read this .po line: {raw}')
    done()
    return header, entries


def render(header, scanned, have, nplurals):
    """.po text: the header, then every scanned string with its translation from `have`."""
    blocks = ['msgid ""\nmsgstr ""\n' + ''.join(_po_quote(p) + '\n' for p in header.splitlines(keepends=True))]
    for (msgid, plural), refs in scanned.items():
        strs = have.get((msgid, plural), {})
        lines = ['#: ' + ' '.join(refs), 'msgid ' + _po_quote(msgid)]
        if plural is None:
            lines.append('msgstr ' + _po_quote(strs.get(0, '')))
        else:
            lines.append('msgid_plural ' + _po_quote(plural))
            lines += [f'msgstr[{k}] ' + _po_quote(strs.get(k, '')) for k in range(nplurals)]
        blocks.append('\n'.join(lines) + '\n')
    return '\n'.join(blocks)


def _read(path):
    try:
        with open(path, encoding='utf-8') as fh:
            return fh.read()
    except FileNotFoundError:
        return None


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(text)


def check_lang(lang, scanned, have, nplurals):
    """Problems of one language's translations."""
    problems = []
    for (msgid, plural) in scanned:
        strs = have.get((msgid, plural))
        if strs is None:
            problems.append(f'{lang}: missing translation: {msgid!r}')
            continue
        forms = [0] if plural is None else list(range(nplurals))
        if any(not strs.get(k) for k in forms):
            problems.append(f'{lang}: empty translation: {msgid!r}')
            continue
        want = PLACEHOLDER.findall(msgid if plural is None else plural)
        for k in forms:
            if PLACEHOLDER.findall(strs[k]) != want:
                problems.append(f'{lang}: placeholders differ from the English in {msgid!r} (form {k}): '
                                f'{PLACEHOLDER.findall(strs[k])} vs {want}')
    for (msgid, plural) in have:
        if (msgid, plural) not in scanned:
            problems.append(f'{lang}: obsolete translation: {msgid!r}')
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--js-dir', default=os.path.join(ROOT, 'luci-app-gatygo', 'htdocs'))
    ap.add_argument('--po-dir', default=os.path.join(ROOT, 'luci-app-gatygo', 'po'))
    args = ap.parse_args()
    try:
        scanned = scan(args.js_dir)
    except ScanError as e:
        print(e, file=sys.stderr)
        return 1
    problems = []
    pot_path = os.path.join(args.po_dir, 'templates', 'gatygo.pot')
    pot = render(POT_HEADER, scanned, {}, 2)
    if not args.check:
        _write(pot_path, pot)
    elif _read(pot_path) != pot:
        problems.append(f'{os.path.relpath(pot_path, ROOT)} is stale: run tools/i18n-scan.py')
    langs = sorted(d for d in os.listdir(args.po_dir)
                   if os.path.isfile(os.path.join(args.po_dir, d, 'gatygo.po'))) if os.path.isdir(args.po_dir) else []
    for lang in langs:
        path = os.path.join(args.po_dir, lang, 'gatygo.po')
        text = _read(path)
        header, have = parse_po(text)
        if header is None:
            problems.append(f'{lang}: the .po has no header')
            continue
        m = NPLURALS.search(header)
        nplurals = int(m.group(1)) if m else 2
        synced = render(header, scanned, have, nplurals)
        if not args.check:
            _write(path, synced)
            continue
        found = check_lang(lang, scanned, have, nplurals)
        if not found and text != synced:
            found.append(f'{os.path.relpath(path, ROOT)} is out of step: run tools/i18n-scan.py')
        problems += found
    for p in problems:
        print(p, file=sys.stderr)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
