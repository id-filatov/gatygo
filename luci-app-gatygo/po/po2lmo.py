#!/usr/bin/env python3
"""Compile a gettext .po file into a LuCI .lmo catalog.

A port of po2lmo.c from LuCI (modules/luci-base/src, openwrt-25.12): the same reading of the .po,
the same keys, hash and file layout, so the output is byte-identical. Run at package build time;
the router never needs Python.

Usage: po2lmo.py input.po output.lmo
"""
import os
import struct
import sys

M32 = 0xffffffff


def _s8(b):
    """A byte as C's signed char."""
    return b - 256 if b > 127 else b


def sfh_hash(data):
    """Paul Hsieh's SuperFastHash as LuCI computes it: lmo.c sfh_hash(data, len, len), cbi.js sfh()."""
    n = len(data)
    if n == 0:
        return 0
    h, i = n, 0
    for _ in range(n >> 2):
        h = (h + (data[i] | data[i + 1] << 8)) & M32
        tmp = (((data[i + 2] | data[i + 3] << 8) << 11) ^ h) & M32
        h = ((h << 16) & M32) ^ tmp
        h = (h + (h >> 11)) & M32
        i += 4
    rem = n & 3
    if rem == 3:
        h = (h + (data[i] | data[i + 1] << 8)) & M32
        h ^= (h << 16) & M32
        h ^= (_s8(data[i + 2]) << 18) & M32
        h = (h + (h >> 11)) & M32
    elif rem == 2:
        h = (h + (data[i] | data[i + 1] << 8)) & M32
        h ^= (h << 11) & M32
        h = (h + (h >> 17)) & M32
    elif rem == 1:
        h = (h + _s8(data[i])) & M32
        h ^= (h << 10) & M32
        h = (h + (h >> 1)) & M32
    h ^= (h << 3) & M32
    h = (h + (h >> 5)) & M32
    h ^= (h << 4) & M32
    h = (h + (h >> 17)) & M32
    h ^= (h << 25) & M32
    h = (h + (h >> 6)) & M32
    return h


def _extract(line):
    """The quoted text of a .po line as po2lmo.c's extract_string reads it: \\" and \\\\ lose their
    backslash, any other escape stays as written. None for comments and lines without a quote."""
    if line[:1] == b'#':
        return None
    out, esc, started = bytearray(), False, False
    for c in line:
        if not started:
            started = c == 0x22
            continue
        if esc:
            if c in (0x22, 0x5c):
                out[-1] = c
            else:
                out.append(c)
            esc = False
        elif c == 0x5c:
            out.append(c)
            esc = True
        elif c != 0x22:
            out.append(c)
        else:
            break
    return bytes(out) if started else None


def _pad(b):
    return b + b'\0' * ((4 - len(b) % 4) % 4)


class _Msg:
    def __init__(self):
        self.ctxt = self.id = self.id_plural = None
        self.val = [None] * 10
        self.plural_num = 0


def compile_po(data):
    """The .lmo bytes for the .po text `data`, or None when there is nothing to write."""
    values, index = bytearray(), []
    msg, cur = _Msg(), None

    def flush():
        if msg.id and msg.val[0]:
            for i in range(msg.plural_num + 1):
                v = msg.val[i]
                if not v:
                    continue
                if msg.ctxt and msg.id_plural:
                    key = msg.ctxt + b'\1' + msg.id + b'\2' + str(i).encode()
                elif msg.ctxt:
                    key = msg.ctxt + b'\1' + msg.id
                elif msg.id_plural:
                    key = msg.id + b'\2' + str(i).encode()
                else:
                    key = msg.id
                if sfh_hash(key) != sfh_hash(v):
                    index.append((sfh_hash(key), msg.plural_num + 1, len(values), len(v)))
                    values.extend(_pad(v))
        elif msg.val[0]:
            v, field, esc = msg.val[0], 0, False
            for p in range(len(v)):
                if esc:
                    if v[p] == 0x6e:  # "\n" ends a header field
                        seg = v[field:p - 1]
                        if seg[:14].lower() == b'plural-forms: ':
                            f = seg[14:]
                            index.append((0, 0, len(values), len(f)))
                            values.extend(_pad(f))
                            break
                        field = p + 1
                    esc = False
                elif v[p] == 0x5c:
                    esc = True

    lines = data.split(b'\n')
    for n, line in enumerate(lines + [None]):
        eof = line is None
        line = line or b''
        if line.startswith(b'msgctxt "'):
            if msg.id or msg.val[0]:
                flush()
                msg = _Msg()
            msg.ctxt, cur = None, 'ctxt'
        elif eof or line.startswith(b'msgid "'):
            if msg.id or msg.val[0]:
                flush()
                msg = _Msg()
            msg.id, cur = None, 'id'
        elif line.startswith(b'msgid_plural "'):
            msg.id_plural, cur = None, 'id_plural'
        elif line.startswith(b'msgstr "') or line.startswith(b'msgstr['):
            msg.plural_num = int(line[7:].split(b']')[0]) if line[6:7] == b'[' else 0
            if msg.plural_num >= 10:
                raise ValueError('too many plural forms')
            msg.val[msg.plural_num], cur = None, msg.plural_num
        if eof:
            break
        if cur is not None:
            s = _extract(line + b'\n')
            if s:
                if isinstance(cur, int):
                    msg.val[cur] = (msg.val[cur] or b'') + s
                else:
                    setattr(msg, cur, (getattr(msg, cur) or b'') + s)
    if not values:
        return None
    index.sort(key=lambda e: e[0])
    return bytes(values) + b''.join(struct.pack('>IIII', *e) for e in index) + struct.pack('>I', len(values))


def main(argv):
    if len(argv) != 3:
        print('Usage: po2lmo.py input.po output.lmo', file=sys.stderr)
        return 1
    try:
        with open(argv[1], 'rb') as fh:
            out = compile_po(fh.read())
    except (OSError, ValueError) as e:
        print(f'po2lmo.py: {e}', file=sys.stderr)
        return 1
    if out is None:
        if os.path.exists(argv[2]):
            os.unlink(argv[2])
        return 0
    with open(argv[2], 'wb') as fh:
        fh.write(out)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
