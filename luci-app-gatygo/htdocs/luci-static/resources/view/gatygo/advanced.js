'use strict';
'require view';
'require poll';
'require rpc';
'require uci';
'require ui';
'require form';

// The page behind the gear of the main page: settings, the balancer's nodes and the log.
// It has no menu entry of its own (its menu.d node has no title); the main page links to it.

var callStatus = rpc.declare({ object: 'gatygo', method: 'status', expect: { } });
var callNodes = rpc.declare({ object: 'gatygo', method: 'nodes', expect: { } });
var callLog = rpc.declare({ object: 'gatygo', method: 'log', params: [ 'lines' ], expect: { log: '' } });

var CSS = [
	'.gg-backrow { margin:.25em 0 .5em; }',
	'.gg-adv-head { display:flex; flex-wrap:wrap; align-items:baseline; justify-content:space-between; gap:.25em 1.5em; }',
	'.gg-adv-head h2 { margin:0; }',
	'.gg-muted { color:var(--text-color-medium); }',
	'.gg-secret { font-family:monospace; padding:.2em .5em; border:1px solid var(--border-color-medium); border-radius:3px; background:var(--background-color-low); }',
	'.gg-nodes .th:nth-child(n+3), .gg-nodes .td:nth-child(n+3) { text-align:right; }',
	'pre.gg-log { max-height:24em; overflow:auto; font-size:12px; line-height:1.45; }'
].join('\n');

function fmtBytes(n) {
	n = +n || 0;
	var units = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	return (i == 0 ? n : n.toFixed(1)) + ' ' + units[i];
}

function maskUrl(u) {
	return (u.length > 20) ? u.slice(0, 12) + '…' + u.slice(-4) : u.slice(0, 8) + '…';
}

return view.extend({
	nodesPane: null,
	logPre: null,

	load: function() {
		return Promise.all([
			callStatus(),
			L.resolveDefault(uci.load('gatygo'), null)
		]);
	},

	renderNodes: function(data) {
		var table = this.nodesPane.querySelector('table');
		var rows = (data.nodes || []).map(function(n) {
			return [
				n.address ? E('span', {}, [ n.address, ' ', E('span', { 'class': 'gg-muted' }, n.tag) ]) : n.tag,
				n.in_use ? E('span', { 'class': 'label success' }, _('yes')) : '',
				fmtBytes(n.up), fmtBytes(n.down)
			];
		});
		cbi_update_table(table, rows, E('em', {}, data.api ? _('No outbounds in the installed configuration.') : _('xray is not running.')));
		var note = this.nodesPane.querySelector('.cbi-section-descr');
		note.textContent = data.balancer
			? _('"In use" marks the nodes the balancer currently sends traffic to. Counters are since the last restart.')
			: _('This profile has a single server and no balancer. Counters are since the last restart.');
	},

	renderLog: function() {
		return callLog(200).then(L.bind(function(text) {
			this.logPre.textContent = text || _('The log is empty.');
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
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			var field = form.Value.prototype.renderWidget.apply(this, arguments);
			if (!cfgvalue) return field;
			field.style.display = 'none';
			var shown = E('span', {}, [
				E('code', { 'class': 'gg-secret' }, maskUrl(cfgvalue)), ' ',
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function(ev) {
					ev.preventDefault();
					shown.style.display = 'none';
					field.style.display = '';
					var input = field.querySelector('input'); if (input) { input.value = ''; input.focus(); }
				} }, _('Change'))
			]);
			return E('div', {}, [ shown, field ]);
		};

		o = s.option(form.Value, 'user_agent', _('User agent'), _("The panel's subscription rules must return Xray JSON for this user agent."));
		o.placeholder = 'gatygo/' + (st.version || '');

		o = s.option(form.Flag, 'send_hwid', _('Send device ID'), _('Sent as the x-hwid header. Panels with a device limit count this router as one device.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.DummyValue, 'hwid', _('Device ID'));
		o.depends('send_hwid', '1');
		o.cfgvalue = function(section_id) { return uci.get('gatygo', section_id, 'hwid') || _('generated on the first update'); };

		o = s.option(form.Value, 'update_interval', _('Update every'), _('Hours. Empty: the interval the subscription suggests (currently %d h).').format(st.update_interval || 12));
		o.datatype = 'uinteger';
		o.placeholder = String(st.update_interval || 12);

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

		this.nodesPane = E('div', { 'data-tab': 'nodes', 'data-tab-title': _('Nodes') }, [
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-descr' }, ''),
				E('table', { 'class': 'table gg-nodes' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Node')),
						E('th', { 'class': 'th' }, _('In use')),
						E('th', { 'class': 'th' }, _('Sent')),
						E('th', { 'class': 'th' }, _('Received'))
					])
				])
			])
		]);
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

		var tabs = E('div', {}, [ settingsPane, this.nodesPane, logPane ]);
		var versions = [ st.version ? 'gatygo ' + st.version : '', st.xray_version ? 'xray ' + st.xray_version : '' ].filter(String).join(' · ');
		var page = E('div', {}, [
			E('style', {}, CSS),
			E('p', { 'class': 'gg-backrow' }, E('a', { 'href': L.url('admin/services/gatygo') }, '← ' + _('Back to gatygo'))),
			E('div', { 'class': 'gg-adv-head' }, [ E('h2', {}, _('Advanced')), E('span', { 'class': 'gg-muted' }, versions) ]),
			tabs
		]);

		var self = this;
		return (haveUci ? this.renderSettings(st) : Promise.resolve(null)).then(function(formNode) {
			if (formNode) settingsPane.appendChild(formNode);
			ui.tabs.initTabGroup(tabs.childNodes);
			poll.add(function() {
				if (!self.nodesPane.hasAttribute('data-tab-active')) return Promise.resolve();
				return callNodes().then(L.bind(self.renderNodes, self));
			}, 10);
			callNodes().then(L.bind(self.renderNodes, self));
			self.renderLog();
			return page;
		});
	}
});
