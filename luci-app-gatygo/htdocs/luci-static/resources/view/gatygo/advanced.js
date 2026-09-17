'use strict';
'require view';
'require dom';
'require rpc';
'require uci';
'require ui';
'require form';

// The page behind the gear of the main page: settings and the log.
// It has no menu entry of its own (its menu.d node has no title); the main page links to it.

var callStatus = rpc.declare({ object: 'gatygo', method: 'status', expect: { } });
var callLog = rpc.declare({ object: 'gatygo', method: 'log', params: [ 'lines' ], expect: { log: '' } });

var CSS = [
	'.gg-adv { --gg-ink-2:hsl(0 0% 32%); --gg-ink-3:hsl(0 0% 45%); --gg-warn-ink:hsl(32 90% 26%); --gg-bad-ink:hsl(0 70% 38%); --gg-accent-ink:hsl(212 80% 36%); }',
	'[data-darkmode="true"] .gg-adv { --gg-ink-2:hsl(0 0% 74%); --gg-ink-3:hsl(0 0% 62%); --gg-warn-ink:hsl(40 85% 68%); --gg-bad-ink:hsl(0 85% 76%); --gg-accent-ink:hsl(212 85% 72%); }',
	'.gg-backrow { margin:.25em 0 .5em; }',
	'.gg-adv-head { display:flex; flex-wrap:wrap; align-items:baseline; justify-content:space-between; gap:.25em 1.5em; }',
	'.gg-adv-head h2 { margin:0; }',
	'.gg-muted { color:var(--gg-ink-2); }',
	'.gg-adv .cbi-value-field select { width:auto; min-width:210px; max-width:100%; }',
	'.gg-url-row { display:flex; flex-wrap:wrap; align-items:center; gap:.5em; }',
	'.gg-url-row input { flex:1 1 16em; width:auto; min-width:0; max-width:34em; font-family:monospace; }',
	'pre.gg-log { max-height:32em; overflow:auto; margin:0 0 1em; font-size:12px; line-height:1.55; white-space:pre-wrap; word-break:break-word; }',
	'.gg-lt, .gg-ltag { color:var(--gg-ink-3); }',
	'.gg-ltag.is-gatygo { color:var(--gg-accent-ink); font-weight:600; }',
	'.gg-lvl { color:var(--gg-ink-3); }',
	'.gg-ll.is-warn .gg-lvl { color:var(--gg-warn-ink); font-weight:600; }',
	'.gg-ll.is-error, .gg-ll.is-error .gg-lvl { color:var(--gg-bad-ink); } .gg-ll.is-error .gg-lvl { font-weight:600; }',
	'.gg-ll.is-debug { color:var(--gg-ink-3); }'
].join('\n');

// https://panel.example.com/sub/AbCdEfGhIjKl -> https://panel.example.com/sub/AbCd***IjKl:
// the server is readable, the secret part of the link is not
function maskUrl(u) {
	var m = /^(https?:\/\/[^\/]+\/(?:.*\/)?)([^\/]*)$/.exec(u);
	if (!m) return u.slice(0, 8) + '***';
	return m[1] + (m[2].length > 10 ? m[2].slice(0, 4) + '***' + m[2].slice(-4) : '***');
}

// "xray: 2026/09/17 16:14:17.599658 [Warning] core: …" and "gatygo: 2026-09-17T16:14:50 [info] …":
// time dimmed, our own lines marked by the tag, warnings and errors by colour
function logLine(line) {
	// lines without a time and a level (xray's start banner) keep the columns
	var m = /^(xray|gatygo): (?:(\d{4}[\/-]\d\d[\/-]\d\d[ T]\d\d:\d\d:\d\d)(?:\.\d+)? \[(\w+)\] )?(.*)$/.exec(line);
	if (!m) return E('span', { 'class': 'gg-ll' }, line + '\n');
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

	load: function() {
		return Promise.all([
			callStatus(),
			L.resolveDefault(uci.load('gatygo'), null)
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
				input.dispatchEvent(new Event('change', { bubbles: true }));
				if (edit) input.focus();
			};
			var shown = E('div', { 'class': 'gg-url-row' }, [
				E('input', { 'class': 'cbi-input-text', 'type': 'text', 'readonly': '', 'value': maskUrl(cfgvalue), 'aria-label': _('Subscription URL, masked') }),
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function(ev) { ev.preventDefault(); swap(true); } }, _('Change'))
			]);
			var editing = E('div', { 'class': 'gg-url-row', 'style': 'display:none' }, [
				field,
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function(ev) { ev.preventDefault(); swap(false); } }, _('Cancel'))
			]);
			return E('div', {}, [ shown, editing ]);
		};

		o = s.option(form.Value, 'user_agent', _('User agent'), _("The panel's subscription rules must return Xray JSON for this user agent."));
		o.placeholder = 'gatygo/' + (st.version || '');

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

		var tabs = E('div', {}, [ settingsPane, logPane ]);
		var versions = [ st.version ? 'gatygo ' + st.version : '', st.xray_version ? 'xray ' + st.xray_version : '' ].filter(String).join(' · ');
		var page = E('div', { 'class': 'gg-adv' }, [
			E('style', {}, CSS),
			E('p', { 'class': 'gg-backrow' }, E('a', { 'href': L.url('admin/services/gatygo') }, '← ' + _('Back to gatygo'))),
			E('div', { 'class': 'gg-adv-head' }, [ E('h2', {}, _('Advanced')), E('span', { 'class': 'gg-muted' }, versions) ]),
			tabs
		]);

		var self = this;
		return (haveUci ? this.renderSettings(st) : Promise.resolve(null)).then(function(formNode) {
			if (formNode) settingsPane.appendChild(formNode);
			ui.tabs.initTabGroup(tabs.childNodes);
			self.renderLog();
			return page;
		});
	}
});
