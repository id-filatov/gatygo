'use strict';
'require view';
'require dom';
'require rpc';
'require uci';
'require ui';
'require form';

// The page behind the gear of the main page: settings, the user's own rules and the log.
// It has no menu entry of its own (its menu.d node has no title); the main page links to it.

var callStatus = rpc.declare({ object: 'gatygo', method: 'status', expect: { } });
var callLog = rpc.declare({ object: 'gatygo', method: 'log', params: [ 'lines' ], expect: { log: '' } });
var callForget = rpc.declare({ object: 'gatygo', method: 'forget', expect: { } });
var callRules = rpc.declare({ object: 'gatygo', method: 'rules', expect: { } });
var callRoute = rpc.declare({ object: 'gatygo', method: 'route', params: [ 'domain' ], expect: { } });
// pending gatygo changes of this session (Save without Apply) would put the old link back
var callUciRevert = rpc.declare({ object: 'uci', method: 'revert', params: [ 'config' ] });

var CSS = [
	'.gg-adv { --gg-ink-2:hsl(0 0% 32%); --gg-ink-3:hsl(0 0% 45%); --gg-warn-ink:hsl(32 90% 26%); --gg-bad-ink:hsl(0 70% 38%); --gg-accent-ink:hsl(212 80% 36%); --gg-ok-ink:hsl(130 55% 30%);',
	'  --gg-warn-tint:hsl(42 95% 93%); --gg-warn-line:hsl(40 75% 76%); }',
	'[data-darkmode="true"] .gg-adv { --gg-ink-2:hsl(0 0% 74%); --gg-ink-3:hsl(0 0% 62%); --gg-warn-ink:hsl(40 85% 68%); --gg-bad-ink:hsl(0 85% 76%); --gg-accent-ink:hsl(212 85% 72%); --gg-ok-ink:hsl(130 45% 70%);',
	'  --gg-warn-tint:hsl(38 45% 15%); --gg-warn-line:hsl(38 40% 28%); }',
	'.gg-backrow { margin:.25em 0 .5em; }',
	'.gg-adv-head { display:flex; flex-wrap:wrap; align-items:baseline; justify-content:space-between; gap:.25em 1.5em; }',
	'.gg-adv-head h2 { margin:0; }',
	'.gg-muted { color:var(--gg-ink-2); }',
	// the main page's Update button, as a link to its confirmation
	'.gg-upgrade { display:inline-flex; align-items:center; gap:6px; height:26px; margin:0 0 0 10px; padding:0 10px; border:1px solid var(--gg-warn-line); border-radius:6px; background:var(--gg-warn-tint); color:var(--gg-warn-ink); font-size:12px; font-weight:600; line-height:1; white-space:nowrap; vertical-align:middle; text-decoration:none; }',
	'.gg-upgrade:hover { color:var(--gg-warn-ink); text-decoration:none; }',
	'.gg-upgrade-sep { width:1px; align-self:stretch; margin:0 2px; background:currentColor; opacity:.3; } .gg-upgrade-v { font-weight:400; opacity:.75; }',
	'@media (max-width:640px) { .gg-upgrade { display:flex; width:fit-content; margin:6px 0 0; } }',
	'.gg-adv .cbi-value-field select { width:auto; min-width:210px; max-width:100%; }',
	'.gg-url-row { display:flex; flex-wrap:wrap; align-items:center; gap:.5em; }',
	// the real field comes wrapped in LuCI's own div: size the wrapper, let the input fill it
	'.gg-url-row > input, .gg-url-row > div { flex:1 1 16em; min-width:0; max-width:34em; }',
	'.gg-url-row input { width:100%; font-family:monospace; }',
	'pre.gg-log { max-height:32em; overflow:auto; margin:0 0 1em; font-size:12px; line-height:1.55; white-space:pre-wrap; word-break:break-word; }',
	'.gg-lt, .gg-ltag { color:var(--gg-ink-3); }',
	'.gg-ltag.is-gatygo { color:var(--gg-accent-ink); font-weight:600; }',
	'.gg-lvl { color:var(--gg-ink-3); }',
	'.gg-ll.is-warn .gg-lvl { color:var(--gg-warn-ink); font-weight:600; }',
	'.gg-ll.is-error, .gg-ll.is-error .gg-lvl { color:var(--gg-bad-ink); } .gg-ll.is-error .gg-lvl { font-weight:600; }',
	'.gg-ll.is-debug { color:var(--gg-ink-3); }',
	'.gg-rule-d { font-family:monospace; }',
	'.gg-adv tr.gg-grp > td { padding-top:.6em; color:var(--gg-ink-3); font-size:11px; text-transform:uppercase; letter-spacing:.04em; }',
	'.gg-adv .cbi-section-actions .gg-rule-x { flex:0 0 auto; min-width:0; width:auto; padding:0 .9em; margin-left:auto; }',
	'.gg-st.is-works { color:var(--gg-ok-ink); } .gg-st.is-nochange { color:var(--gg-ink-3); } .gg-st.is-bad { color:var(--gg-bad-ink); }',
	'.gg-rules-add, .gg-check-row { display:flex; flex-wrap:wrap; align-items:center; gap:.5em; }',
	'.gg-rules-add input, .gg-check-row input { flex:1 1 12em; min-width:0; max-width:24em; }',
	'.gg-rules-add select, .gg-rules-add button { flex:0 0 auto; width:auto; min-width:0; }',
	'.gg-err { flex-basis:100%; color:var(--gg-bad-ink); }',
	'.gg-err:empty { display:none; }',
	'.gg-check { margin-top:1.5em; }',
	'.gg-check h4 { margin:0 0 .5em; }',
	'.gg-check-res { margin-top:.5em; }'
].join('\n');

// Tabler's download icon (MIT), as on the main page
function downloadIcon() {
	var ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg');
	var attrs = { 'width': 13, 'height': 13, 'viewBox': '0 0 24 24', 'fill': 'none', 'stroke': 'currentColor', 'stroke-width': 2.2,
		'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' };
	for (var k in attrs) svg.setAttribute(k, attrs[k]);
	[ 'M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2 -2v-2', 'M7 11l5 5l5 -5', 'M12 4l0 12' ].forEach(function(d) {
		var p = document.createElementNS(ns, 'path'); p.setAttribute('d', d); svg.appendChild(p);
	});
	return svg;
}

// https://panel.example.com/sub/AbCdEfGhIjKl -> https://panel.example.com/sub/AbCd***IjKl:
// the server is readable, the secret part of the link is not
function maskUrl(u) {
	var m = /^(https?:\/\/[^\/]+\/(?:.*\/)?)([^\/]*)$/.exec(u);
	if (!m) return u.slice(0, 8) + '***';
	return m[1] + (m[2].length > 10 ? m[2].slice(0, 4) + '***' + m[2].slice(-4) : '***');
}

// Delete the subscription. A fresh status picks the words: the VPN may have started or stopped
// since the page opened, and a crashed xray with on_crash=block keeps the LAN closed until the
// stop. Afterwards the router is as after a fresh install: the main page shows the setup screen.
function confirmForget() {
	var main = L.url('admin/services/gatygo');
	return callStatus().then(function(st) {
		var live = st.running === true || st.crashed != null;
		var label = live ? _('Stop and delete') : _('Delete');
		var note = E('p', {});
		var cancel = E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Cancel'));
		var go = E('button', { 'class': 'btn cbi-button cbi-button-negative important' }, label);
		var back = function(text) {
			dom.content(note, text);
			go.disabled = cancel.disabled = false;
			go.textContent = label;
		};
		// Deleted: only now drop this session's pending gatygo changes (Save without Apply), which
		// would put the old link back; a delete that did not happen leaves them as they were.
		var done = function() {
			return L.resolveDefault(callUciRevert('gatygo'), null).then(function() { window.location.href = main; });
		};
		// The request may give up (LuCI after 20 s, rpcd after 30 s) on a slow stop that still
		// completes: trust the status, not the error. forget holds the update lock while it works, so
		// `updating` says it is not over yet: ask again every 2 s, for up to 90 s.
		var afterError = function(text, left) {
			return L.resolveDefault(callStatus(), {}).then(function(now) {
				if (now.configured === false) return done();
				else if (now.updating === true && left > 0)
					return new Promise(function(resolve) { window.setTimeout(resolve, 2000); }).then(function() { return afterError(text, left - 1); });
				else back(text);
			});
		};
		// Busy: an update, or a delete pressed in another tab. While the modal stays open and idle,
		// follow the status for up to 90 s and go along when the subscription is gone.
		var watch = function(left) {
			window.setTimeout(function() {
				if (left <= 0 || !document.body.contains(note) || go.disabled) return;
				L.resolveDefault(callStatus(), {}).then(function(now) {
					if (now.configured === false && !go.disabled) done();
					else watch(left - 1);
				});
			}, 2000);
		};
		go.addEventListener('click', function() {
			go.disabled = cancel.disabled = true;
			go.textContent = _('Deleting…');
			dom.content(note, '');
			callForget().then(function(r) {
				if (r && r.result == 'ok') return done();
				else if (r && r.result == 'busy') {
					back(_('An update is running. Try again in a minute.'));
					watch(45);
				}
				else return afterError([ _('The subscription could not be deleted.'), E('br'), (r && r.message) || '' ], 45);
			}).catch(function(e) {
				return afterError([ _('The subscription could not be deleted.'), E('br'), String((e && e.message) || e) ], 45);
			});
		});
		ui.showModal(_('Delete the subscription?'), [
			live ? E('p', {}, _('The VPN stops and your devices go online directly, without the VPN.')) : '',
			st.send_hwid ? E('p', {}, _('Your provider still counts this router as a device: remove it in your account if you need the slot back.')) : '',
			note,
			E('div', { 'class': 'right' }, [ cancel, ' ', go ])
		]);
	}).catch(function(e) {
		ui.addNotification(null, E('p', {}, [ _('The router did not answer: %s').format((e && e.message) || e) ]), 'error');
	});
}

// "https://Example.com:8443/x", "пример.рф", " example.com " -> the domain the router checks
// (lib/rules.sh): lowercase, punycode, no scheme, port or path; null when it is not one
function normDomain(s) {
	s = (s || '').trim();
	if (!s) return null;
	if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) s = 'http://' + s;
	var h;
	try { h = new URL(s).hostname; } catch (e) { return null; }
	h = h.replace(/\.$/, '');
	if (h.length > 253 || /\.\d+$/.test(h)
	    || !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(h))
		return null;
	return h;
}

// " 203.0.113.7/24 ", "2001:DB8::1", "http://[2001:db8::1]/" -> the address or subnet in the one
// form the router stores and compares (lib/addr.sh): IPv4 without leading zeros, IPv6 per RFC 5952,
// host bits zeroed, no /32 or /128; null when it is not one. A link's host is taken as typed: the
// URL parser would read 010.1.1.1 as octal and 1.2.3 as 1.2.0.3.
function normAddr(s) {
	var dec = function(x, max) { return /^(0|[1-9]\d{0,2})$/.test(x) && +x <= max ? +x : -1; };
	s = (s || '').trim().toLowerCase();
	var link = /^[a-z][a-z0-9+.-]*:\/\/(?:[^@\/?#]*@)?(\[[^\]]*\]|[^:\/?#]*)/.exec(s);
	if (link) s = link[1].replace(/^\[(.*)\]$/, '$1');
	var p = s.split('/'), m = -1;
	if (p.length > 2) return null;
	if (p.length == 2 && (m = dec(p[1], 128)) < 0) return null;
	s = p[0];
	if (s.indexOf(':') < 0) {
		var q = s.split('.'), n = 0;
		if (q.length != 4 || m > 32) return null;
		for (var i = 0; i < 4; i++) {
			var o = dec(q[i], 255);
			if (o < 0) return null;
			n = n * 256 + o;
		}
		if (m < 0) m = 32;
		var b = Math.pow(2, 32 - m);
		n = Math.floor(n / b) * b;
		var a = [ Math.floor(n / 16777216), Math.floor(n / 65536) % 256, Math.floor(n / 256) % 256, n % 256 ].join('.');
		return m < 32 ? a + '/' + m : a;
	}
	if (!/^[0-9a-f:]+$/.test(s)) return null;
	var halves = s.split('::');
	if (halves.length > 2) return null;
	var groups = function(h) { return h == '' ? [] : h.split(':'); };
	var l = groups(halves[0]), r = halves.length == 2 ? groups(halves[1]) : [];
	if (halves.length == 2 ? l.length + r.length > 7 : l.length != 8) return null;
	if (l.concat(r).some(function(x) { return !/^[0-9a-f]{1,4}$/.test(x); })) return null;
	var g = l.concat(new Array(8 - l.length - r.length).fill('0'), r).map(function(x) { return parseInt(x, 16); });
	if (m < 0) m = 128;
	for (var k = 0; k < 8; k++) {
		var bits = m - k * 16;
		if (bits <= 0) g[k] = 0;
		else if (bits < 16) g[k] = Math.floor(g[k] / Math.pow(2, 16 - bits)) * Math.pow(2, 16 - bits);
	}
	// the longest run of two or more zero groups becomes "::", the first of equal ones
	var bs = -1, bl = 1;
	for (var j = 0, rs = -1; j <= 8; j++) {
		if (j < 8 && g[j] == 0) { if (rs < 0) rs = j; continue; }
		if (rs >= 0 && j - rs > bl) { bs = rs; bl = j - rs; }
		rs = -1;
	}
	var hex = function(a) { return a.map(function(x) { return x.toString(16); }).join(':'); };
	var out = bs < 0 ? hex(g) : hex(g.slice(0, bs)) + '::' + hex(g.slice(bs + bl));
	return m < 128 ? out + '/' + m : out;
}

// what is typed in the rules row or the check: {ip} for an address or subnet, else {domain}; null
// when it is neither
function normEntry(s) {
	var a = normAddr(s);
	if (a) return { ip: a };
	var d = normDomain(s);
	return d ? { domain: d } : null;
}

// proxy | direct | block, as the router answers (lib/route.sh)
function routeWord(to) {
	return { proxy: _('tunnel'), direct: _('direct'), block: _('blocked') }[to];
}

// a rule's status (lib/route.sh): [kind, text]
function statusText(code) {
	switch (code) {
	case 'works': return [ 'works', _('✓ The rule works') ];
	case 'nochange': return [ 'nochange', _('— The rule changes nothing') ];
	case 'provider_direct': return [ 'bad', _('✗ The rule does not work: the VPN provider sends it direct') ];
	case 'provider_proxy': return [ 'bad', _('✗ The rule does not work: the VPN provider sends it through the tunnel') ];
	case 'provider_block': return [ 'bad', _('✗ The rule does not work: the VPN provider blocks it') ];
	case 'ipv6_blocked': return [ 'bad', _('✗ The rule does not work: IPv6 is off in the gatygo settings') ];
	case 'ipv6_bypass': return [ 'bad', _('✗ The rule does not work: IPv6 goes around the VPN') ];
	case 'local': return [ 'bad', _('✗ The rule does not work: the local network always goes direct') ];
	}
	return null;
}

// "xray: 2026/09/17 16:14:17.599658 [Warning] core: …" and "gatygo: 2026-09-17T16:14:50 [info] …":
// time dimmed, our own lines marked by the tag, warnings and errors by colour
function logLine(line) {
	// lines without a time and a level (xray's start banner) keep the columns
	var m = /^(xray|gatygo): (?:(\d{4}[\/-]\d\d[\/-]\d\d[ T]\d\d:\d\d:\d\d)(?:\.\d+)? \[(\w+)\] )?(.*)$/.exec(line);
	if (!m) return E('span', { 'class': 'gg-ll' }, [ line + '\n' ]);
	var lvl = (m[3] || '').toLowerCase();
	if (lvl == 'warning') lvl = 'warn';
	return E('span', { 'class': 'gg-ll' + (lvl ? ' is-' + lvl : '') }, [
		E('span', { 'class': 'gg-lt' }, ((m[2] || '').replace(/\//g, '-').replace('T', ' ') + ' '.repeat(19)).slice(0, 19)), ' ',
		E('span', { 'class': 'gg-ltag is-' + m[1] }, (m[1] + '  ').slice(0, 6)), ' ',
		E('span', { 'class': 'gg-lvl' }, (lvl + '     ').slice(0, 5)), ' ', m[4], '\n'
	]);
}

return view.extend({
	logPre: null,
	rules: null,

	load: function() {
		return Promise.all([
			callStatus(),
			L.resolveDefault(uci.load('gatygo'), null),
			L.resolveDefault(callRules(), null)
		]);
	},

	// The status of the rule in section SID: only for a rule as saved and applied (a direction
	// changed on the page, or a row not applied yet, has none), and only while xray can tell.
	ruleStatus: function(sid) {
		var r = this.rules;
		if (!r || !r.available || !r.api || r.pending) return null;
		// an address is looked up as the router reads it: the file may hold it as typed by hand
		var d = uci.get('gatygo', sid, 'domain'), ip = d ? null : normAddr(uci.get('gatygo', sid, 'ip')), to = uci.get('gatygo', sid, 'to');
		var hit = (r.rules || []).filter(function(x) { return (d ? x.domain == d : ip != null && x.ip == ip) && x.to == to; })[0];
		return hit ? hit.status : null;
	},

	paintStatus: function(el, sid, blank) {
		var s = blank ? null : statusText(this.ruleStatus(sid));
		el.className = 'gg-st' + (s ? ' is-' + s[0] : '');
		el.textContent = s ? s[1] : '';
	},

	// the Check row as the last answer allows: no answer at all, xray not running, its API silent
	paintCheck: function() {
		if (!this.checkBtn) return;
		var r = this.rules;
		var note = !r ? _('Could not check') : !r.available ? _('The check works while the VPN is on') : !r.api ? _('Could not check') : '';
		this.checkBtn.disabled = !!note;
		this.checkNote.textContent = note;
	},

	// ask again while the answer can still change by itself: the router is applying the saved
	// rules (Save & Apply, an update), xray's API is not up yet after a restart, or the call failed
	pollRules: function(left) {
		var r = this.rules;
		if (left <= 0 || (r && !r.pending && (!r.available || r.api))) return;
		window.setTimeout(L.bind(function() {
			L.resolveDefault(callRules(), null).then(L.bind(function(r) {
				if (r) {
					this.rules = r;
					document.querySelectorAll('[data-gg-rule]').forEach(L.bind(function(el) {
						this.paintStatus(el, el.getAttribute('data-gg-rule'));
					}, this));
				}
				this.paintCheck();
				this.pollRules(left - 1);
			}, this));
		}, this), 3000);
	},

	renderRules: function() {
		var self = this, r = this.rules || {};
		var m = new form.Map('gatygo', null, _('VPN provider rules take priority. A domain covers its subdomains.') + ' '
			+ _('An address works where no site name is seen: Telegram, calls, games. For sites, add the domain.'));
		var s = m.section(form.GridSection, 'rule');
		var o;
		s.anonymous = true;
		s.addremove = true;
		s.nodescriptions = true;

		// the domains, then the addresses, each in the order they were added, under a heading of
		// their own (none for a group without rules)
		var isAddr = function(sid) { return !uci.get('gatygo', sid, 'domain') && !!uci.get('gatygo', sid, 'ip'); };
		s.cfgsections = function() {
			var all = form.GridSection.prototype.cfgsections.apply(this, arguments);
			return all.filter(function(sid) { return !isAddr(sid); }).concat(all.filter(isAddr));
		};
		s.renderContents = function(cfgsections, nodes) {
			var el = form.GridSection.prototype.renderContents.apply(this, arguments);
			var heads = {};
			el.querySelectorAll('tbody > tr[data-sid]').forEach(function(tr) {
				var g = isAddr(tr.getAttribute('data-sid')) ? 'addr' : 'domain';
				if (heads[g]) return;
				heads[g] = true;
				tr.parentNode.insertBefore(E('tr', { 'class': 'tr gg-grp' },
					E('td', { 'class': 'td', 'colspan': tr.children.length }, g == 'addr' ? _('Addresses') : _('Domains'))), tr);
			});
			return el;
		};

		o = s.option(form.DummyValue, 'domain', _('Domain or address'));
		o.textvalue = function(sid) {
			return E('span', { 'class': 'gg-rule-d' }, uci.get('gatygo', sid, 'domain') || uci.get('gatygo', sid, 'ip') || '');
		};

		o = s.option(form.ListValue, 'to', _('Route'));
		o.editable = true;
		o.value('proxy', _('tunnel'));
		o.value('direct', _('direct'));
		o.default = 'proxy';
		// a row added from the row below has no widget yet when the form is parsed: keep its value
		o.retain = true;
		// a direction not saved yet: the status shown is of the other one
		o.onchange = function(ev, sid) {
			var el = document.querySelector('[data-gg-rule="%s"]'.format(sid));
			if (el) self.paintStatus(el, sid, true);
		};

		// the title goes in as HTML: the country's name is the subscription's, not ours
		o = s.option(form.DummyValue, '_status', r.profile ? _('Now, in %s').format('%h'.format(r.profile)) : '');
		o.textvalue = function(sid) {
			var el = E('span', { 'data-gg-rule': sid });
			self.paintStatus(el, sid);
			return el;
		};

		s.renderRowActions = function(sid) {
			return E('td', { 'class': 'td cbi-section-table-cell nowrap cbi-section-actions' }, E('div', {},
				E('button', { 'class': 'btn cbi-button cbi-button-remove gg-rule-x', 'title': _('Delete'),
					'click': ui.createHandlerFn(this, 'handleRemove', sid) }, '×')));
		};

		// a row under the table: the domain or address, the direction, Add (GridSection's own Add opens a modal)
		s.renderSectionAdd = function() {
			var map = this.map;
			var input = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'placeholder': _('domain or address') });
			var dir = E('select', { 'class': 'cbi-input-select' }, [
				E('option', { 'value': 'proxy' }, _('tunnel')), E('option', { 'value': 'direct' }, _('direct')) ]);
			var err = E('div', { 'class': 'gg-err' });
			var add = function() {
				var e = normEntry(input.value);
				if (!e) return dom.content(err, _('A domain or an address is needed, for example example.com or 203.0.113.0/24'));
				if (e.ip && uci.sections('gatygo', 'rule').some(function(x) { return x.ip && normAddr(x.ip) == e.ip; }))
					return dom.content(err, _('This address is already listed'));
				if (e.domain && uci.sections('gatygo', 'rule').some(function(x) { return x.domain == e.domain; }))
					return dom.content(err, _('This domain is already listed'));
				var sid = uci.add('gatygo', 'rule');
				uci.set('gatygo', sid, e.ip ? 'ip' : 'domain', e.ip || e.domain);
				uci.set('gatygo', sid, 'to', dir.value);
				return map.save(null, true);
			};
			input.addEventListener('keydown', function(ev) { if (ev.key == 'Enter') { ev.preventDefault(); add(); } });
			return E('div', { 'class': 'cbi-section-create gg-rules-add' }, [
				input, dir, E('button', { 'class': 'cbi-button cbi-button-add', 'click': ui.createHandlerFn(this, add) }, _('Add')), err ]);
		};

		return m.render();
	},

	renderCheck: function() {
		var input = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'placeholder': 'example.com', 'aria-label': _('Domain or address') });
		var res = E('div', { 'class': 'gg-check-res' });
		var check = function() {
			var e = normEntry(input.value);
			if (!e) return dom.content(res, E('span', { 'class': 'gg-err' }, _('A domain or an address is needed, for example example.com or 203.0.113.0/24')));
			var d = e.ip || e.domain;
			// why: the address never reaches the VPN (lib/route.sh)
			return callRoute(d).then(function(a) {
				dom.content(res, [ !(a && a.to) ? _('Could not check')
					: a.why == 'ipv6_blocked' ? _('%s → IPv6 is off in the gatygo settings').format(d)
					: a.why == 'ipv6_bypass' ? _('%s → IPv6 goes around the VPN').format(d)
					: a.why == 'local' ? _('%s → direct (local network)').format(d)
					: d + ' → ' + routeWord(a.to) ]);
			}).catch(function() { dom.content(res, _('Could not check')); });
		};
		var btn = this.checkBtn = E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, check) }, _('Check'));
		this.checkNote = E('span', { 'class': 'gg-muted' });
		this.paintCheck();
		input.addEventListener('keydown', function(ev) { if (ev.key == 'Enter' && !btn.disabled) { ev.preventDefault(); btn.click(); } });
		return E('div', { 'class': 'cbi-section gg-check' }, [
			E('h4', {}, _('Where will a site go?')),
			E('div', { 'class': 'gg-check-row' }, [ input, btn, this.checkNote ]),
			res
		]);
	},

	renderLog: function() {
		return callLog(200).then(L.bind(function(text) {
			var lines = (text || '').split('\n').filter(String);
			dom.content(this.logPre, lines.length ? lines.map(logLine) : _('The log is empty.'));
			this.logPre.scrollTop = this.logPre.scrollHeight;
		}, this));
	},

	renderSettings: function(st) {
		var m = new form.Map('gatygo', null, _('Changes take effect after Save & Apply: the subscription is downloaded again with the new settings.'));
		var s = m.section(form.NamedSection, 'main', 'gatygo');
		var o;

		o = s.option(form.Flag, 'enabled', _('Enable'), _('Start the tunnel at boot and keep it running.'));
		o.rmempty = false;

		o = s.option(form.Value, 'sub_url', _('Subscription URL'), _('Stored on the router only. The log never shows it.'));
		o.rmempty = false;
		o.placeholder = 'https://';
		o.validate = function(section_id, value) {
			return (!value || /^https?:\/\/\S+$/.test(value)) ? true : _('Expecting an http:// or https:// URL');
		};
		// A stored link is shown masked, in a field of its own; Change swaps in the real, empty field.
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			var field = form.Value.prototype.renderWidget.apply(this, arguments);
			if (!cfgvalue) return field;
			var input = field.querySelector('input');
			var swap = function(edit) {
				shown.style.display = edit ? 'none' : '';
				editing.style.display = edit ? '' : 'none';
				input.value = edit ? '' : cfgvalue;
				// an empty field is no mistake until the user leaves it; going back clears a complaint
				if (edit) input.focus();
				else [ 'keyup', 'blur', 'change' ].forEach(function(t) { input.dispatchEvent(new Event(t, { bubbles: true })); });
			};
			var shown = E('div', { 'class': 'gg-url-row' }, [
				E('input', { 'class': 'cbi-input-text', 'type': 'text', 'readonly': '', 'value': maskUrl(cfgvalue), 'aria-label': _('Subscription URL, masked') }),
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function(ev) { ev.preventDefault(); swap(true); } }, _('Change')),
				E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function(ev) { ev.preventDefault(); confirmForget(); } }, _('Delete'))
			]);
			var editing = E('div', { 'class': 'gg-url-row', 'style': 'display:none' }, [
				field,
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function(ev) { ev.preventDefault(); swap(false); } }, _('Cancel'))
			]);
			return E('div', {}, [ shown, editing ]);
		};

		// The provider's server picks the answer format by this name. The list: apps that take
		// Xray JSON subscriptions, which servers commonly know; anything else goes in as custom.
		o = s.option(form.Value, 'user_agent', _('User agent'), _("Your provider's server picks the format of the list by this name, and gatygo needs Xray JSON. If the default is not recognised, choose the app your provider supports."));
		o.placeholder = 'gatygo/' + (st.version || '') + ' (' + _('default') + ')';
		[ 'Happ/3.0.0', 'v2rayNG/1.10.5', 'v2rayN/7.13.2', 'Streisand/1.6.40' ].forEach(function(ua) { o.value(ua); });

		o = s.option(form.Flag, 'send_hwid', _('Send device ID'), _('Sent as the x-hwid header. Panels with a device limit count this router as one device.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.DummyValue, 'hwid', _('Device ID'));
		o.depends('send_hwid', '1');
		o.cfgvalue = function(section_id) { return uci.get('gatygo', section_id, 'hwid') || _('generated on the first update'); };

		// a fixed choice: a free number invites 0 or a year
		var every = uci.get('gatygo', 'main', 'update_interval') || '';
		o = s.option(form.ListValue, 'update_interval', _('Update every'), _('How often the list of countries is downloaded again.'));
		o.value('', every ? _('As the subscription suggests') : _('As the subscription suggests (%d h)').format(st.update_interval || 12));
		[ '1', '3', '6', '12', '24' ].concat(every).filter(function(h, i, all) { return h && all.indexOf(h) == i; })
			.sort(function(a, b) { return a - b; })
			.forEach(function(h) { o.value(h, (h == '1') ? _('Every hour') : _('Every %d hours').format(+h)); });

		o = s.option(form.Flag, 'ipv6_block', _('Block LAN IPv6'), _('IPv6 is not proxied. Blocking it keeps devices with IPv6 addresses from bypassing the tunnel.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'on_crash', _('If the VPN stops by itself'),
			_('It is rare, but xray can quit, for example when the router runs out of memory. Blocking keeps everything inside the VPN at the price of no internet at home until someone presses Start. Either way the main page says what happened and when.'));
		o.value('block', _('Block the internet until the VPN is back'));
		o.value('direct', _('Let devices use the regular internet'));
		o.default = 'block';

		// empty = the default the daemon uses (lib/config.sh)
		o = s.option(form.Value, 'conn_per_device', _('Connections per device'),
			_('At most this many connections of one device go through the VPN at a time; new ones over it are refused. A busy device, a torrent client say, cannot take the memory xray needs for the whole home.'));
		o.datatype = 'range(1,65535)';
		o.placeholder = '600';

		o = s.option(form.Value, 'conn_total', _('Connections in all'),
			_('At most this many connections of all devices together. Each one costs xray 50–70 KB of memory: 1000 suits a router with 256 MB.'));
		o.datatype = 'range(1,65535)';
		o.placeholder = '1000';

		o = s.option(form.Value, 'direct_dns', _('Resolver for server names'), _("Used only to resolve the VPN servers' own host names, outside the tunnel. Empty: the WAN DNS."));
		o.datatype = 'ip4addr';
		o.placeholder = _('WAN DNS');

		o = s.option(form.ListValue, 'loglevel', _('Log level'));
		o.value('warning'); o.value('info'); o.value('debug'); o.value('error'); o.value('none');
		o.default = 'warning';

		return m.render();
	},

	render: function(data) {
		var st = data[0], haveUci = (data[1] !== null);
		this.rules = data[2];

		this.logPre = E('pre', { 'class': 'gg-log' }, _('Loading…'));
		var logPane = E('div', { 'data-tab': 'log', 'data-tab-title': _('Log') }, [
			E('div', { 'class': 'cbi-section' }, [
				this.logPre,
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.createHandlerFn(this, 'renderLog') }, _('Refresh')),
				' ', E('span', { 'class': 'gg-muted' }, _('Last 200 xray and gatygo lines of the system log'))
			])
		]);
		var settingsPane = E('div', { 'data-tab': 'settings', 'data-tab-title': _('Settings') },
			haveUci ? [] : [ E('div', { 'class': 'alert-message notice' }, _('Your account cannot read the gatygo settings.')) ]);

		var rulesPane = E('div', { 'data-tab': 'rules', 'data-tab-title': _('My rules') },
			haveUci ? [] : [ E('div', { 'class': 'alert-message notice' }, _('Your account cannot read the gatygo settings.')) ]);

		var tabs = E('div', {}, [ settingsPane, rulesPane, logPane ]);
		var versions = [ st.version ? 'gatygo ' + st.version : '', st.xray_version ? 'xray ' + st.xray_version : '' ].filter(String).join(' · ');
		// a newer release: the main page shows the upgrade, this link opens its confirmation there
		var up = st.upgrade || {}, upgrade = (up.available && !(up.run && up.run.state == 'running'))
			? E('a', { 'class': 'gg-upgrade', 'href': L.url('admin/services/gatygo') + '?upgrade=1' },
				[ downloadIcon(), _('Update'), E('span', { 'class': 'gg-upgrade-sep' }), E('span', { 'class': 'gg-upgrade-v' }, [ up.latest ]) ]) : '';
		var page = E('div', { 'class': 'gg-adv' }, [
			E('style', {}, CSS),
			E('p', { 'class': 'gg-backrow' }, E('a', { 'href': L.url('admin/services/gatygo') }, '← ' + _('Back to gatygo'))),
			E('div', { 'class': 'gg-adv-head' }, [ E('h2', {}, _('Advanced')), E('span', {}, [ E('span', { 'class': 'gg-muted' }, versions), upgrade ]) ]),
			tabs
		]);

		var self = this;
		return Promise.all([
			haveUci ? this.renderSettings(st) : null,
			haveUci ? this.renderRules() : null
		]).then(function(nodes) {
			if (nodes[0]) settingsPane.appendChild(nodes[0]);
			if (nodes[1]) { rulesPane.appendChild(nodes[1]); rulesPane.appendChild(self.renderCheck()); }
			ui.tabs.initTabGroup(tabs.childNodes);
			self.renderLog();
			self.pollRules(40);
			return page;
		});
	}
});
