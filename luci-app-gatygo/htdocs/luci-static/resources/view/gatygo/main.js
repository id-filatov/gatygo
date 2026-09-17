'use strict';
'require view';
'require dom';
'require poll';
'require rpc';
'require ui';

// The main page: one block. The connection state with the country in it and the on/off and
// update buttons, the subscription facts, whether the usual services open through the tunnel,
// and every profile of the subscription as a button. Settings and the log live on the Advanced
// page behind the gear.

var callStatus = rpc.declare({ object: 'gatygo', method: 'status', expect: { } });
var callUpdate = rpc.declare({ object: 'gatygo', method: 'update', expect: { started: false } });
var callSelect = rpc.declare({ object: 'gatygo', method: 'select', params: [ 'profile' ], expect: { } });
var callConnect = rpc.declare({ object: 'gatygo', method: 'connect', params: [ 'url' ], expect: { } });
var callCheck = rpc.declare({ object: 'gatygo', method: 'check', params: [ 'fresh' ], expect: { } });
var callInitAction = rpc.declare({ object: 'luci', method: 'setInitAction', params: [ 'name', 'action' ], expect: { result: false } });

var CSS = [
	'.gg { --gg-ink:var(--text-color-highest); --gg-ink-2:hsl(0 0% 32%); --gg-ink-3:hsl(0 0% 45%); --gg-line:hsl(0 0% 86%); --gg-line-2:hsl(0 0% 92%);',
	'  --gg-accent:var(--primary-color-high); --gg-accent-tint:hsl(210 80% 96%); --gg-on:var(--success-color-medium); --gg-off:hsl(0 0% 62%); --gg-bad:hsl(0 72% 50%); --gg-good:hsl(150 60% 27%); --gg-slow:hsl(30 85% 31%);',
	'  --gg-warn-ink:hsl(32 90% 26%); --gg-warn-tint:hsl(42 95% 93%); --gg-warn-line:hsl(40 75% 76%);',
	'  --gg-bad-ink:hsl(0 70% 38%); --gg-bad-tint:hsl(0 85% 96%); --gg-bad-line:hsl(0 65% 84%);',
	'  --gg-ease:cubic-bezier(.23,1,.32,1); font-variant-numeric:tabular-nums; min-width:0; overflow-wrap:anywhere; }',
	'[data-darkmode="true"] .gg { --gg-ink-2:hsl(0 0% 74%); --gg-ink-3:hsl(0 0% 62%); --gg-line:hsl(0 0% 27%); --gg-line-2:hsl(0 0% 21%);',
	'  --gg-accent-tint:hsl(210 30% 20%); --gg-off:hsl(0 0% 48%); --gg-bad:hsl(0 75% 58%); --gg-good:hsl(150 45% 62%); --gg-slow:hsl(38 75% 62%);',
	'  --gg-warn-ink:hsl(40 85% 68%); --gg-warn-tint:hsl(38 45% 15%); --gg-warn-line:hsl(38 40% 28%);',
	'  --gg-bad-ink:hsl(0 85% 76%); --gg-bad-tint:hsl(0 40% 16%); --gg-bad-line:hsl(0 40% 30%); }',
	'.gg-sr { position:absolute; width:1px; height:1px; overflow:hidden; clip-path:inset(50%); }',
	'.gg-card { margin-top:14px; padding:20px 24px 24px; border:1px solid var(--border-color-medium); border-radius:8px; background:var(--background-color-low); }',
	'.gg-card-head { display:grid; grid-template-columns:minmax(0,1.25fr) minmax(0,1fr) auto; grid-template-areas:"main facts gear"; gap:16px 40px; align-items:start; }',
	'.gg-card-main { grid-area:main; min-width:0; }',
	'.gg-state { display:flex; flex-wrap:wrap; align-items:baseline; gap:4px 10px; margin:0 0 8px; font-size:22px; line-height:1.25; font-weight:600; letter-spacing:-.01em; color:var(--gg-ink); }',
	'.gg-state small { font-size:15px; font-weight:400; letter-spacing:0; color:var(--gg-ink-2); }',
	'.gg-dot { flex:none; align-self:center; width:10px; height:10px; border-radius:50%; background:var(--gg-off); }',
	'.gg-dot.on { background:var(--gg-on); box-shadow:0 0 0 4px color-mix(in srgb, var(--gg-on) 24%, transparent); }',
	'.gg-dot.bad { background:var(--gg-bad); box-shadow:0 0 0 4px color-mix(in srgb, var(--gg-bad) 22%, transparent); }',
	'.gg-dot.warn { background:var(--warn-color-high); animation:gg-pulse 1s ease-in-out infinite; }',
	'@keyframes gg-pulse { 50% { opacity:.35; } }',
	'.gg-state-sep { color:var(--gg-ink-3); font-weight:400; }',
	'.gg-state-country { display:inline-flex; align-items:center; gap:8px; min-width:0; }',
	'.gg-state-country.is-idle { color:var(--gg-ink-2); font-weight:500; }',
	'.gg-meta { margin:0; max-width:72ch; font-size:13px; line-height:1.5; color:var(--gg-ink-2); }',
	'.gg-facts { grid-area:facts; display:flex; flex-direction:column; gap:8px; margin:4px 0 0; min-width:0; }',
	'.gg-facts div { display:flex; gap:12px; align-items:baseline; }',
	'.gg-facts dt { flex:none; width:96px; font-size:13px; font-weight:400; color:var(--gg-ink-3); }',
	'.gg-facts dd { margin:0; font-size:13px; color:var(--gg-ink); }',
	'.gg-facts dd.bad { color:var(--gg-bad-ink); font-weight:600; }',
	'.gg-gear { grid-area:gear; justify-self:end; display:grid; place-items:center; width:36px; height:36px; margin:-6px -8px 0 0; border-radius:6px; color:var(--gg-ink-2); transition:background-color 150ms var(--gg-ease), transform 120ms var(--gg-ease); }',
	'.gg-gear svg { transition:transform 400ms var(--gg-ease); }',
	'@media (hover:hover) and (pointer:fine) { .gg-gear:hover { background:var(--gg-line-2); color:var(--gg-ink); } .gg-gear:hover svg { transform:rotate(60deg); } .gg-chip:not(:disabled):not(.is-on):hover { border-color:var(--gg-ink-3); } .gg-icon-btn:not(:disabled):hover { background:var(--gg-line-2); color:var(--gg-ink); } }',
	'.gg-gear:active { transform:scale(.94); }',
	'.gg-gear:focus-visible, .gg-chip:focus-visible, .gg-icon-btn:focus-visible, .gg .cbi-button:focus-visible { outline:2px solid var(--gg-accent); outline-offset:2px; }',
	'.gg-alert { display:flex; align-items:flex-start; gap:12px; margin-top:16px; padding:12px 14px; border:1px solid var(--gg-warn-line); border-radius:6px; background:var(--gg-warn-tint); }',
	'.gg-alert.bad { border-color:var(--gg-bad-line); background:var(--gg-bad-tint); }',
	'.gg-alert-icon { flex:none; margin-top:1px; color:var(--gg-warn-ink); }',
	'.gg-alert.bad .gg-alert-icon { color:var(--gg-bad-ink); }',
	'.gg-alert-body { flex:1 1 0; min-width:0; }',
	'.gg-alert-title { margin:0; font-size:14px; line-height:1.4; font-weight:600; color:var(--gg-ink); }',
	'.gg-alert-text { margin:2px 0 0; max-width:80ch; font-size:13px; line-height:1.5; color:var(--gg-ink-2); }',
	'.gg-detail { margin:6px 0 0; font:12px/1.5 monospace; color:var(--gg-ink-2); }',
	'.gg-alert-actions { flex:none; align-self:center; }',
	'.gg-alert-actions a { text-decoration:none; }',
	'.gg-card-check { display:grid; grid-template-columns:minmax(0,1fr) auto; align-items:center; gap:4px 24px; margin-top:20px; padding-top:16px; border-top:1px solid var(--gg-line); }',
	'.gg-checks { display:flex; flex-wrap:wrap; gap:6px 28px; margin:0; padding:0; list-style:none; }',
	'.gg-check { display:inline-flex; align-items:center; gap:6px; font-size:13px; line-height:1.5; color:var(--gg-ink); }',
	'.gg-check svg { flex:none; color:var(--gg-good); } .gg-check.is-none svg { color:var(--gg-bad-ink); } .gg-check.is-wait svg { color:var(--gg-ink-3); }',
	'.gg-check-name { font-weight:600; } .gg-check.is-none .gg-check-name { font-weight:500; color:var(--gg-ink-2); }',
	'.gg-check-ms { display:inline-flex; align-items:center; min-width:44px; font-size:12px; color:var(--gg-ink-3); }',
	'.gg-check-ms.good { color:var(--gg-good); } .gg-check-ms.slow { color:var(--gg-slow); } .gg-check-ms.bad, .gg-check-ms.none { color:var(--gg-bad-ink); }',
	'.gg-check-ms.wait::before { content:""; width:34px; height:8px; border-radius:4px; background:linear-gradient(90deg, var(--gg-line-2) 25%, var(--gg-line) 50%, var(--gg-line-2) 75%) 0 0 / 200% 100%; animation:gg-shimmer 1.1s linear infinite; }',
	'@keyframes gg-shimmer { to { background-position:-200% 0; } }',
	'.gg-checked { display:inline-flex; align-items:center; gap:6px; margin:0; justify-self:end; font-size:12px; color:var(--gg-ink-2); }',
	'.gg-icon-btn { display:grid; place-items:center; width:28px; height:28px; margin:0; padding:0; border:0; border-radius:6px; background:none; color:var(--gg-ink-2); cursor:pointer; transition:background-color 150ms var(--gg-ease), transform 120ms var(--gg-ease); }',
	'.gg-icon-btn:disabled { cursor:default; } .gg-icon-btn:disabled svg { animation:gg-spin .9s linear infinite; }',
	'.gg-icon-btn:not(:disabled):active { transform:scale(.94); }',
	'.gg-check-hint { grid-column:1 / -1; margin:2px 0 0; font-size:12px; line-height:1.5; color:var(--gg-warn-ink); }',
	'.gg-card-pick { margin-top:20px; padding-top:20px; border-top:1px solid var(--gg-line); }',
	'.gg-chips { display:flex; flex-wrap:wrap; gap:8px; }',
	'.gg-chip { position:relative; display:inline-flex; align-items:center; gap:8px; height:38px; margin:0; padding:0 14px 0 10px; border:1px solid var(--gg-line); border-radius:6px; background:var(--background-color-high); color:var(--gg-ink); font:inherit; font-size:13px; line-height:1; cursor:pointer; transition:border-color 150ms var(--gg-ease), background-color 150ms var(--gg-ease), transform 120ms var(--gg-ease); }',
	'.gg-chip-flag { font-size:18px; line-height:1; }',
	'.gg-chip:not(:disabled):not(.is-on):active { transform:scale(.97); }',
	'.gg-chip.is-on { border-color:var(--gg-accent); background:var(--gg-accent-tint); box-shadow:inset 0 0 0 1px var(--gg-accent); font-weight:600; }',
	'.gg-chip.is-on, .gg-chip:disabled { cursor:default; }',
	'.gg-chip:disabled { color:var(--gg-ink); opacity:1; }',
	'.gg-chip:disabled:not(.is-on) { opacity:.5; }',
	'.gg-chip.is-busy { padding-right:34px; }',
	'.gg-chip.is-busy::after { content:""; position:absolute; right:12px; width:12px; height:12px; border-radius:50%; border:2px solid var(--gg-accent); border-right-color:transparent; animation:gg-spin .7s linear infinite; }',
	'@keyframes gg-spin { to { transform:rotate(360deg); } }',
	'.gg-hint { margin:12px 0 0; font-size:12px; line-height:1.5; color:var(--gg-ink-2); }',
	'.gg-card-foot { display:flex; margin-top:16px; }',
	'.gg-actions { display:flex; flex-wrap:wrap; gap:8px; margin-top:14px; }',
	'.gg .cbi-button { transition:transform 120ms var(--gg-ease); }',
	'.gg .cbi-button:not(:disabled):active { transform:scale(.97); }',
	'.gg-sign { margin:0 0 0 auto; font-size:13px; line-height:1.5; color:var(--gg-ink-2); }',
	'.gg-sign b { margin-right:6px; font-weight:700; letter-spacing:-.01em; color:var(--gg-ink); }',
	'.gg-field { display:flex; gap:8px; align-items:center; max-width:640px; margin:16px 0 0; }',
	'.gg-field input { flex:1 1 0; width:0; min-width:0; height:40px; padding:0 12px; font-size:15px; }',
	'.gg-field .cbi-button { font-size:15px; line-height:2.7em; padding:0 22px; }',
	'.gg-field.is-bad input { border-color:var(--gg-bad); box-shadow:0 0 0 1px var(--gg-bad); }',
	'.gg-field-error { margin:10px 0 0; max-width:72ch; font-size:13px; line-height:1.5; color:var(--gg-bad-ink); }',
	'@media (max-width:860px) {',
	'  .gg-card { position:relative; }',
	'  .gg-card-head { grid-template-columns:minmax(0,1fr); grid-template-areas:"main" "facts"; gap:8px; }',
	'  .gg-card-main { padding-right:40px; }',
	'  .gg-gear { position:absolute; top:8px; right:8px; margin:0; grid-area:auto; }',
	'  .gg-facts { margin-top:8px; }',
	'  .gg-card-check { grid-template-columns:minmax(0,1fr); }',
	'  .gg-checks { display:grid; grid-template-columns:1fr 1fr; gap:8px 16px; } .gg-check-ms { margin-left:auto; justify-content:flex-end; } }',
	'@media (max-width:640px) {',
	'  .gg-card { padding:16px 16px 20px; }',
	'  .gg-state { font-size:20px; } .gg-state-sep { display:none; } .gg-state-country { flex-basis:100%; order:3; }',
	'  .gg-chips { flex-direction:column; gap:6px; } .gg-chip { height:44px; }',
	'  .gg-gear { width:44px; height:44px; }',
	'  .gg-alert { flex-wrap:wrap; } .gg-alert-body { flex-basis:calc(100% - 32px); } .gg-alert-actions { flex-basis:100%; padding-left:32px; }',
	'  .gg-actions .cbi-button { flex:1 1 auto; }',
	'  .gg-field { flex-direction:column; align-items:stretch; } .gg-field input { width:auto; flex:none; } }',
	'@media (prefers-reduced-motion:reduce) { .gg *, .gg *::after { transition-duration:0ms !important; } .gg-dot.warn, .gg-check-ms.wait::before { animation:none; } .gg-gear:hover svg { transform:none; } }'
].join('\n');

// Tabler icons (MIT). width/height are attributes: an icon never grows when the styles are missing.
var ICONS = {
	gear: [ 18, 1.8, 'M10.325 4.317c.426 -1.756 2.924 -1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543 -.94 3.31 .826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756 .426 1.756 2.924 0 3.35a1.724 1.724 0 0 0 -1.066 2.573c.94 1.543 -.826 3.31 -2.37 2.37a1.724 1.724 0 0 0 -2.572 1.065c-.426 1.756 -2.924 1.756 -3.35 0a1.724 1.724 0 0 0 -2.573 -1.066c-1.543 .94 -3.31 -.826 -2.37 -2.37a1.724 1.724 0 0 0 -1.065 -2.572c-1.756 -.426 -1.756 -2.924 0 -3.35a1.724 1.724 0 0 0 1.066 -2.573c-.94 -1.543 .826 -3.31 2.37 -2.37c1 .608 2.296 .07 2.572 -1.065', 'M9 12a3 3 0 1 0 6 0a3 3 0 0 0 -6 0' ],
	warn: [ 20, 2, 'M12 9v4', 'M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0', 'M12 16h.01' ],
	bad: [ 20, 2, 'M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0', 'M12 8v4', 'M12 16h.01' ],
	ok: [ 14, 2.4, 'M5 12l5 5l10 -10' ],
	none: [ 14, 2.4, 'M18 6l-12 12', 'M6 6l12 12' ],
	wait: [ 14, 2.4, 'M12 12m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0' ],
	refresh: [ 15, 2, 'M20 11a8.1 8.1 0 0 0 -15.5 -2m-.5 -4v4h4', 'M4 13a8.1 8.1 0 0 0 15.5 2m.5 4v-4h-4' ]
};

function icon(name, cls) {
	var i = ICONS[name], ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg');
	var attrs = { 'width': i[0], 'height': i[0], 'viewBox': '0 0 24 24', 'fill': 'none', 'stroke': 'currentColor', 'stroke-width': i[1],
		'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' };
	for (var k in attrs) svg.setAttribute(k, attrs[k]);
	if (cls) svg.setAttribute('class', cls);
	i.slice(2).forEach(function(d) { var p = document.createElementNS(ns, 'path'); p.setAttribute('d', d); svg.appendChild(p); });
	return svg;
}

function fmtDuration(sec) {
	sec = Math.max(0, Math.floor(sec));
	var d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
	if (d > 0) return _('%d d %d h').format(d, h);
	if (h > 0) return _('%d h %d min').format(h, m);
	return _('%d min').format(m);
}

function fmtBytes(n) {
	n = +n || 0;
	var units = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	return (i == 0 ? n : n.toFixed(1)) + ' ' + units[i];
}

function fmtAgo(epoch) {
	var s = Math.floor(Date.now() / 1000) - epoch;
	if (s < 60) return _('just now');
	var n;
	if (s < 3600) { n = Math.floor(s / 60); return N_(n, '%d minute ago', '%d minutes ago').format(n); }
	if (s < 86400) { n = Math.floor(s / 3600); return N_(n, '%d hour ago', '%d hours ago').format(n); }
	n = Math.floor(s / 86400); return N_(n, '%d day ago', '%d days ago').format(n);
}

function fmtIn(epoch) {
	return fmtDuration(epoch - Math.floor(Date.now() / 1000));
}

// Panels put a flag or another emoji in front of the profile name: show it as the flag.
function splitFlag(remarks) {
	var m = /^((?:[\u{1F1E6}-\u{1F1FF}]){2}|\p{Extended_Pictographic}\uFE0F?)\s*(.+)$/u.exec(remarks || '');
	return m ? { flag: m[1], name: m[2] } : { flag: '', name: remarks || '' };
}

function country(remarks, idle) {
	var p = splitFlag(remarks);
	return E('span', { 'class': 'gg-state-country' + (idle ? ' is-idle' : '') }, [ p.flag ? E('span', {}, p.flag) : '', p.name ]);
}

return view.extend({
	status: null,
	busy: null,            // 'select' | 'update' | 'init' | 'connect' while an action runs
	busyProfile: null,     // the profile being switched to
	urlError: null,        // the first-run link did not look like a link
	painted: null,         // what the panel was last painted from
	check: null,           // the last services check: {available, tunnel, time, services}
	checking: false,       // a check is running
	checkedTunnel: null,   // the tunnel (profile and xray pid) the last check was started for; null = page just opened
	panel: null,

	// no form on this page: no Save & Apply footer
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return callStatus();
	},

	// Repaint only when something visible changed (times are shown to the minute), and keep what
	// the user holds: the focused control and a half-typed link.
	repaint: function() {
		var st = this.status;
		var key = JSON.stringify([ st, this.busy, this.busyProfile, this.urlError, this.check, this.checking, Math.floor(Date.now() / 60000) ],
			function(k, v) { return (k == 'uptime' && v != null) ? Math.floor(v / 60) : v; });
		if (key == this.painted) return;
		this.painted = key;

		var active = document.activeElement, focus = (active && this.panel.contains(active)) ? active.getAttribute('data-key') : null;
		var url = this.panel.querySelector('.gg-url'), draft = url ? url.value : null;
		dom.content(this.panel, this.renderPanel(st));
		url = this.panel.querySelector('.gg-url');
		if (url && draft != null) url.value = draft;
		if (focus) {
			var el = this.panel.querySelector('[data-key="' + focus.replace(/["\\]/g, '\\$&') + '"]');
			if (el && !el.disabled) el.focus();
		}
	},

	refresh: function() {
		return callStatus().then(L.bind(function(st) {
			this.status = st;
			this.syncCheck();
			this.repaint();
		}, this));
	},

	// The services check belongs to one tunnel. A tunnel the page has not checked yet (the page
	// just opened, another country, a start, an update that restarted xray) gets a check by
	// itself: the daemon's recent result when the page opens, a new run after a change, once the
	// tunnel had a moment to come up.
	syncCheck: function() {
		var st = this.status;
		if (st.running !== true || !st.profile_used) { this.check = null; if (this.checkedTunnel != null) this.checkedTunnel = ''; return; }
		var tunnel = st.profile_used + ':' + st.pid;
		if (this.busy || this.checking || tunnel == this.checkedTunnel) return;
		var first = (this.checkedTunnel == null);
		this.checkedTunnel = tunnel;
		if (first) return this.runCheck(false);
		// the numbers on the page are another tunnel's: blank them now, measure in a moment
		this.checking = true;
		window.setTimeout(L.bind(this.runCheck, this, true), 2000);
	},

	runCheck: function(fresh) {
		this.checking = true;
		this.repaint();
		return callCheck(!!fresh).then(L.bind(function(r) { this.check = r; }, this), L.bind(function() { this.check = null; }, this))
			.then(L.bind(function() { this.checking = false; this.repaint(); }, this));
	},

	handleCheck: function(ev) {
		return this.runCheck(true);
	},

	run: function(kind, promise) {
		this.busy = kind;
		this.repaint();
		return promise.catch(function(e) { ui.addNotification(null, E('p', e.message), 'error'); })
			.then(L.bind(function() { this.busy = null; this.busyProfile = null; return this.refresh(); }, this));
	},

	handleSelect: function(profile, ev) {
		if (profile == this.status.profile_used && this.status.last_update.code != 'profile_missing') return;
		this.busyProfile = profile;
		return this.run('select', callSelect(profile));
	},

	handleUpdate: function(ev) {
		return this.run('update', callUpdate().then(function(started) {
			if (!started)
				ui.addNotification(null, E('p', _('An update is already running.')), 'warning');
		}));
	},

	handleInit: function(action, ev) {
		return this.run('init', callInitAction('gatygo', action).then(function() {
			// procd needs a moment before the instance shows up or disappears
			return new Promise(function(resolve) { window.setTimeout(resolve, 3000); });
		}));
	},

	// First run: the daemon stores the link, enables the service and starts it; the first start
	// downloads the subscription. The page then follows the status: Setting up, then Connected
	// or the form again with what went wrong.
	handleConnect: function(ev) {
		ev.preventDefault();
		var url = this.panel.querySelector('.gg-url').value.trim();
		if (!/^https?:\/\/\S+$/.test(url)) {
			this.urlError = _('This does not look like a link. It starts with https://');
			this.repaint();
			return;
		}
		this.urlError = null;
		return this.run('connect', callConnect(url).then(function(r) {
			if (r.error) throw new Error(r.error);
			// the download shows up in the status a moment after the start
			return new Promise(function(resolve) { window.setTimeout(resolve, 3000); });
		}));
	},

	// What went wrong, in the user's words. The daemon's own message goes below as the detail.
	problem: function(st, running) {
		var lu = st.last_update || {}, info = st.userinfo || {};
		var exp = +info.expire || 0, total = +info.total || 0, used = (+info.upload || 0) + (+info.download || 0);
		var kept = running ? ' ' + _('You stay connected with the previous settings.') : '';
		var retry = { label: _('Try again'), handler: 'handleUpdate' };

		if (exp && exp * 1000 < Date.now())
			return { bad: true, state: _('Subscription expired'), title: _('Your subscription ended on %s').format(new Date(exp * 1000).toLocaleDateString()),
				text: _('The VPN servers no longer accept this router, so sites may not open. Renew the subscription with your provider, then press Update now.') };
		if (total && used >= total)
			return { bad: true, state: _('Traffic used up'), title: _('You have used all %s of this period').format(fmtBytes(total)),
				text: _('The VPN servers stop serving this router until your provider resets the counter or you buy more traffic. After that press Update now.') };
		if (lu.result != 'error' && lu.result != 'warning')
			return null;

		var p = { detail: lu.message };
		switch (lu.code) {
		case 'fetch_failed':
			p.title = _('Couldn’t update the list of countries');
			p.text = _('Your provider’s server did not answer %s.').format(fmtAgo(+lu.time)) + kept +
				((running && st.next_update) ? ' ' + _('gatygo tries again in %s.').format(fmtIn(st.next_update)) : '');
			p.action = retry;
			break;
		case 'device_limit':
			p.title = _('Too many devices on this subscription');
			p.text = _('Your provider limits the number of devices and the limit is reached. Remove a device in your provider’s account, then try again.') + kept;
			p.action = retry;
			break;
		case 'not_recognised':
			p.title = _('Your provider’s server did not recognise this router');
			p.text = _('It answered, but not with a list of countries. Ask your provider whether routers are supported, or change User agent in Settings.') + kept;
			p.action = { label: _('Open settings'), href: L.url('admin/services/gatygo/advanced') };
			break;
		case 'test_failed':
			p.title = _('The new settings from your provider did not pass the check');
			p.text = _('gatygo tests every update before using it, and this one failed.') + kept;
			p.action = retry;
			break;
		case 'profile_missing':
			if (!st.profile || st.profile == st.profile_used) return null;
			p.title = _('%s is no longer in your subscription').format(splitFlag(st.profile).name);
			p.text = _('gatygo uses %s instead. Tap another country if you prefer.').format(splitFlag(st.profile_used).name);
			// choosing the replacement makes it the saved country, so the warning does not come back
			p.action = { label: _('OK'), handler: 'handleSelect', arg: st.profile_used };
			break;
		case 'apply_failed':
			p.title = _('Couldn’t switch to %s').format(splitFlag(st.profile).name);
			p.text = _('The country in use is still %s.').format(splitFlag(st.profile_used).name);
			p.action = { label: _('Try again'), handler: 'handleSelect', arg: st.profile };
			break;
		case 'no_cache':
			p.title = _('There is no list of countries yet');
			p.text = _('Press Try again to download it.');
			p.action = retry;
			break;
		default:
			p.title = (lu.result == 'error') ? _('The last update failed') : _('The last update finished with a warning');
			p.text = kept.trim();
		}
		return p;
	},

	renderAlert: function(p, dis) {
		var action = '';
		if (p.action && p.action.href)
			action = E('a', { 'class': 'cbi-button cbi-button-neutral', 'href': p.action.href }, p.action.label);
		else if (p.action)
			action = E('button', { 'class': 'cbi-button cbi-button-neutral', 'type': 'button', 'disabled': dis, 'data-key': 'alert-action',
				'click': (p.action.arg != null) ? ui.createHandlerFn(this, p.action.handler, p.action.arg) : ui.createHandlerFn(this, p.action.handler) }, p.action.label);
		return E('div', { 'class': 'gg-alert' + (p.bad ? ' bad' : ''), 'role': p.bad ? 'alert' : 'status' }, [
			icon(p.bad ? 'bad' : 'warn', 'gg-alert-icon'),
			E('div', { 'class': 'gg-alert-body' }, [
				E('p', { 'class': 'gg-alert-title' }, p.title),
				p.text ? E('p', { 'class': 'gg-alert-text' }, p.text) : '',
				p.detail ? E('p', { 'class': 'gg-detail' }, p.detail) : ''
			]),
			action ? E('div', { 'class': 'gg-alert-actions' }, action) : ''
		]);
	},

	// Do the usual services open through the tunnel? The mark says whether, the colour of the
	// number how fast (the time to the end of the TLS handshake). Plain items: only ↻ is a button.
	renderCheck: function() {
		var c = this.check, busy = this.checking;
		if (!c || !c.available || !Array.isArray(c.services) || !c.services.length) return '';
		var items = c.services.map(function(sv) {
			var ms = sv.ms, st = busy ? 'wait' : (ms == null) ? 'none' : 'ok';
			return E('li', { 'class': 'gg-check is-' + st }, [ icon(st), E('span', { 'class': 'gg-check-name' }, sv.name),
				E('span', { 'class': 'gg-check-ms ' + (busy ? 'wait' : ms == null ? 'none' : ms < 1000 ? 'good' : ms < 2000 ? 'slow' : 'bad') },
					busy ? '' : (ms == null) ? _('no reply') : (ms < 1000) ? _('%d ms').format(ms) : _('%s s').format((ms / 1000).toFixed(1))) ]);
		});
		var none = !busy && c.services.every(function(sv) { return sv.ms == null; });
		return E('div', { 'class': 'gg-card-check' }, [
			E('ul', { 'class': 'gg-checks', 'title': _('Checked through the VPN'), 'aria-live': 'polite' }, items),
			E('p', { 'class': 'gg-checked' }, [ busy ? _('Checking…') : _('Checked %s').format(fmtAgo(+c.time)),
				E('button', { 'class': 'gg-icon-btn', 'type': 'button', 'disabled': busy ? '' : null, 'title': _('Check again'), 'aria-label': _('Check again'),
					'data-key': 'recheck', 'click': ui.createHandlerFn(this, 'handleCheck') }, icon('refresh')) ]),
			none ? E('p', { 'class': 'gg-check-hint' }, _('Nothing opens through this country. Try another one.')) : ''
		]);
	},

	// the first-run form: paste the link, press Connect
	renderSetup: function(st, dis) {
		var lu = st.last_update || {}, error = this.urlError, detail = null;
		if (!error && st.configured && lu.result == 'error') {
			detail = lu.message;
			error = (lu.code == 'fetch_failed') ? _('This link did not work. Check that you copied the whole link from your provider.')
				: (lu.code == 'not_recognised') ? _('The server answered, but not with a list of countries. Ask your provider whether routers are supported, or change User agent in Settings (the gear).')
				: (lu.code == 'device_limit') ? _('Too many devices on this subscription. Remove a device in your provider’s account and try again.')
				: _('gatygo could not set up the connection.');
		}
		return [
			E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-dot' }), _('Not set up yet') ]),
			E('p', { 'class': 'gg-meta' }, _('Paste the subscription link from your VPN provider. gatygo downloads the list of countries and connects your whole home network.')),
			E('form', { 'class': 'gg-field' + (error ? ' is-bad' : ''), 'novalidate': '', 'submit': ui.createHandlerFn(this, 'handleConnect') }, [
				E('input', { 'class': 'cbi-input-text gg-url', 'type': 'url', 'placeholder': 'https://', 'aria-label': _('Subscription link'), 'autocomplete': 'off', 'data-key': 'url' }),
				E('button', { 'class': 'cbi-button cbi-button-action important', 'type': 'submit', 'disabled': dis, 'data-key': 'connect' }, _('Connect'))
			]),
			error ? E('p', { 'class': 'gg-field-error' }, error) : '',
			detail ? E('p', { 'class': 'gg-detail' }, detail) : ''
		];
	},

	renderPanel: function(st) {
		var running = st.running === true, updating = st.updating === true, hasConfig = !!st.profile_used;
		var profiles = Array.isArray(st.profiles) ? st.profiles : [], lu = st.last_update || {};
		// E() writes every non-null attribute, so a boolean false would still disable the control
		var dis = (!!this.busy || updating) ? '' : null;
		var problem = (hasConfig && this.busy != 'select') ? this.problem(st, running) : null;
		var main = [], facts = [];

		if (!hasConfig && (updating || this.busy == 'connect')) {
			main.push(E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-dot warn' }), _('Setting up') ]));
			main.push(E('p', { 'class': 'gg-meta' }, E('span', { 'class': 'spinning' }, _('Downloading the list of countries…'))));
		}
		else if (!hasConfig) {
			main = this.renderSetup(st, dis);
		}
		else if (this.busy == 'select' && running) {
			main.push(E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-dot warn' }), _('Switching'),
				E('span', { 'class': 'gg-state-sep' }, '·'), country(this.busyProfile) ]));
			main.push(E('p', { 'class': 'gg-meta' }, _('Connections drop for a few seconds.')));
		}
		else if (running) {
			main.push(E('p', { 'class': 'gg-state' }, (problem && problem.state)
				? [ E('span', { 'class': 'gg-dot bad' }), problem.state, E('span', { 'class': 'gg-state-sep' }, '·'), country(st.profile_used, true) ]
				: [ E('span', { 'class': 'gg-dot on' }), _('Connected'), E('span', { 'class': 'gg-state-sep' }, '·'), country(st.profile_used),
					(st.uptime != null) ? E('small', {}, fmtDuration(st.uptime)) : '' ]));
			if (updating || this.busy == 'update')
				main.push(E('p', { 'class': 'gg-meta' }, E('span', { 'class': 'spinning' }, _('Updating the list of countries…'))));
			else
				main.push(E('p', { 'class': 'gg-meta' }, [
					(lu.time && lu.result != 'error') ? _('Updated %s.').format(fmtAgo(+lu.time)) + ' ' : '',
					st.next_update ? _('Next update in %s.').format(fmtIn(st.next_update)) : '' ]));
		}
		else {
			main.push(E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-dot' }), _('Disconnected'),
				E('span', { 'class': 'gg-state-sep' }, '·'), country(this.busyProfile || st.profile_used, true) ]));
			main.push(E('p', { 'class': 'gg-meta' }, (updating || this.busy == 'update')
				? E('span', { 'class': 'spinning' }, _('Updating the list of countries…'))
				: _('Your home network is using the regular internet. Start connects to the selected country right away.')));
		}

		if (hasConfig) {
			var info = st.userinfo || {}, used = (+info.upload || 0) + (+info.download || 0), total = +info.total || 0, exp = +info.expire || 0;
			if (st.title) facts.push(E('div', {}, [ E('dt', {}, _('Subscription')), E('dd', {}, st.title) ]));
			if (used || total)
				facts.push(E('div', {}, [ E('dt', {}, _('Traffic')), E('dd', { 'class': (total && used >= total) ? 'bad' : null },
					total ? _('%s of %s used').format(fmtBytes(used), fmtBytes(total)) : _('%s used, no limit').format(fmtBytes(used))) ]));
			if (exp) {
				var days = Math.floor((exp - Date.now() / 1000) / 86400);
				facts.push(E('div', {}, [ E('dt', {}, _('Expires')), E('dd', { 'class': (days < 0) ? 'bad' : null },
					new Date(exp * 1000).toLocaleDateString() + ', ' + (days >= 0 ? N_(days, 'in %d day', 'in %d days').format(days) : _('expired %s').format(fmtAgo(exp)))) ]));
			}
		}

		var selected = (this.busy == 'select') ? this.busyProfile : st.profile_used;
		var chips = profiles.map(L.bind(function(p) {
			var f = splitFlag(p.remarks), on = (p.remarks == selected);
			return E('button', { 'class': 'gg-chip' + (on ? ' is-on' : '') + (on && this.busy == 'select' ? ' is-busy' : ''), 'type': 'button',
				'aria-pressed': on ? 'true' : 'false', 'disabled': dis, 'title': p.description || null,
				'data-key': 'chip:' + p.remarks, 'click': ui.createHandlerFn(this, 'handleSelect', p.remarks) },
				[ f.flag ? E('span', { 'class': 'gg-chip-flag' }, f.flag) : '', E('span', {}, f.name) ]);
		}, this));

		var button = L.bind(function(cls, label, handler, arg) {
			return E('button', { 'class': 'cbi-button ' + cls, 'type': 'button', 'disabled': dis, 'data-key': 'act:' + label,
				'click': (arg != null) ? ui.createHandlerFn(this, handler, arg) : ui.createHandlerFn(this, handler) }, label);
		}, this);
		// the on/off button keeps its place whatever the state; Stop then Start is the restart
		if (hasConfig)
			main.push(E('div', { 'class': 'gg-actions' }, [
				running ? button('cbi-button-negative', _('Stop'), 'handleInit', 'stop') : button('cbi-button-apply', _('Start'), 'handleInit', 'start'),
				button('cbi-button-action', _('Update now'), 'handleUpdate') ]));

		return E('section', { 'class': 'gg-card' }, [
			E('div', { 'class': 'gg-card-head' }, [
				E('div', { 'class': 'gg-card-main' }, main),
				facts.length ? E('dl', { 'class': 'gg-facts' }, facts) : '',
				E('a', { 'class': 'gg-gear', 'href': L.url('admin/services/gatygo/advanced'), 'title': _('Advanced: settings, nodes, log'),
					'aria-label': _('Advanced: settings, nodes, log'), 'data-key': 'gear' }, icon('gear'))
			]),
			problem ? this.renderAlert(problem, dis) : '',
			(hasConfig && running && this.busy != 'select') ? this.renderCheck() : '',
			(hasConfig && chips.length) ? E('div', { 'class': 'gg-card-pick' }, [
				E('div', { 'class': 'gg-chips', 'role': 'group', 'aria-label': _('Country') }, chips),
				E('p', { 'class': 'gg-hint' }, running ? _('Tap a country to switch. Connections drop for a few seconds.') : _('Tap a country to choose where Start connects.'))
			]) : '',
			E('div', { 'class': 'gg-card-foot' }, E('p', { 'class': 'gg-sign' }, [ E('b', {}, 'gatygo'), st.version || '' ]))
		]);
	},

	render: function(st) {
		this.status = st;
		this.panel = E('div', {});
		this.syncCheck();
		this.repaint();
		poll.add(L.bind(this.refresh, this), 5);
		return E('div', { 'class': 'gg' }, [ E('style', {}, CSS), E('h2', { 'class': 'gg-sr' }, 'gatygo'), this.panel ]);
	}
});
