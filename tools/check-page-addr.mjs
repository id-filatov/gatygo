#!/usr/bin/env node
// The page reads an address the way the daemon does (gatygo/files/lib/addr.sh): run normAddr from
// advanced.js on the cases of tests/unit/test_addr.sh, plus the links only the page shortens.
//   node tools/check-page-addr.mjs   -> "N passed, M failed", exit 1 on a failure
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const js = readFileSync(join(root, 'luci-app-gatygo/htdocs/luci-static/resources/view/gatygo/advanced.js'), 'utf8');
const sh = readFileSync(join(root, 'tests/unit/test_addr.sh'), 'utf8');

let pass = 0, fail = 0;
const check = (want, got, what) => {
	if (want === got) pass++;
	else { fail++; console.error(`FAIL: ${what}\n  expected: ${want}\n  actual:   ${got}`); }
};

// the function alone: from its first line to the first "}" at the start of a line
const start = js.indexOf('function normAddr(');
let normAddr = null;
if (start < 0) check('normAddr in advanced.js', 'not found', 'normAddr is defined');
else {
	const end = js.indexOf('\n}', start);
	normAddr = new Function(js.slice(start, end + 2) + '\nreturn normAddr;')();
}

// the valid cases: the heredoc of "norm:" lines
const table = sh.slice(sh.indexOf("<<'EOF'\n") + 8, sh.indexOf('\nEOF\n'));
const good = table.split('\n').map((l) => l.trim().split(/\s+/));
// the invalid ones: the words of "for bad in ...; do", shell quoting and line continuations
const words = sh.slice(sh.indexOf('for bad in') + 10, sh.indexOf('; do', sh.indexOf('for bad in'))).replace(/\\\n/g, ' ');
const bad = [];
for (const m of words.matchAll(/'([^']*)'|(\S+)/g)) bad.push(m[1] ?? m[2]);
check(true, good.length > 10 && bad.length > 10, 'the cases are read from test_addr.sh');

const links = [
	['https://203.0.113.5:8443/x', '203.0.113.5'],
	['http://[2001:DB8::1]/', '2001:db8::1'],
	[' 203.0.113.7/24 ', '203.0.113.0/24'],
];
// a link's host is read as typed: no URL parser reading 010 as octal or 1.2.3 as 1.2.0.3
const badLinks = ['http://010.1.1.1/', 'http://1.2.3/', 'http://0x7f.0.0.1/', 'https://example.com/'];

if (normAddr) {
	for (const [i, w] of [...good, ...links]) check(w, normAddr(i), `norm: '${i}'`);
	// the page trims what is typed ('1.2.3.4 ' is fine there), the daemon gets it trimmed
	for (const b of [...bad.filter((b) => b.trim() === b), ...badLinks]) check(null, normAddr(b), `not an address: '${b}'`);
}
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
