'use strict';
'require view';
'require dom';
'require poll';
'require rpc';
'require uci';
'require ui';
'require form';

var callStatus = rpc.declare({ object: 'gatygo', method: 'status', expect: { } });
var callNodes = rpc.declare({ object: 'gatygo', method: 'nodes', expect: { } });
var callLog = rpc.declare({ object: 'gatygo', method: 'log', params: [ 'lines' ], expect: { log: '' } });
var callUpdate = rpc.declare({ object: 'gatygo', method: 'update', expect: { started: false } });
var callSelect = rpc.declare({ object: 'gatygo', method: 'select', params: [ 'profile' ], expect: { } });
var callInitAction = rpc.declare({ object: 'luci', method: 'setInitAction', params: [ 'name', 'action' ], expect: { result: false } });

var CSS = [
	'.gg-status { display:flex; flex-wrap:wrap; gap:1.5em 3em; align-items:flex-start; padding:1em 1.2em; margin-bottom:1em; border:1px solid var(--border-color-medium); border-radius:4px; background:var(--background-color-low); }',
	'.gg-status .gg-main { flex:1 1 22em; min-width:0; }',
	'.gg-state { font-size:1.35em; line-height:1.3; margin:0 0 .25em; color:var(--text-color-high); }',
	'.gg-sub { color:var(--text-color-medium); margin:0; }',
	'.gg-actions { display:flex; flex-wrap:wrap; gap:.5em; align-items:center; }',
	'.gg-facts { display:grid; grid-template-columns:max-content 1fr; gap:.35em 1.2em; margin:0; flex:1 1 20em; }',
	'.gg-facts dt { color:var(--text-color-medium); font-weight:400; } .gg-facts dd { margin:0; }',
	'.gg-muted { color:var(--text-color-medium); } .gg-ok { color:var(--success-color-high); } .gg-bad { color:var(--error-color-high); } .gg-warn { color:var(--warn-color-high); }',
	'.gg-secret { font-family:monospace; padding:.2em .5em; border:1px solid var(--border-color-medium); border-radius:3px; background:var(--background-color-low); }',
	'.gg-nodes .th:nth-child(n+3), .gg-nodes .td:nth-child(n+3) { text-align:right; }',
	'pre.gg-log { max-height:24em; overflow:auto; font-size:12px; line-height:1.45; }'
].join('\n');

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

function maskUrl(u) {
	return (u.length > 20) ? u.slice(0, 12) + '…' + u.slice(-4) : u.slice(0, 8) + '…';
}

return view.extend({
	status: null,
	busy: null,            // 'select' | 'update' | 'init' while an action runs
	updateSince: 0,        // last_update.time when Update now was pressed
	panel: null,
	nodesPane: null,
	logPre: null,

	load: function() {
		return Promise.all([
			callStatus(),
			L.resolveDefault(uci.load('gatygo'), null)
		]);
	},

	// re-render the panel, keeping a profile the user has picked but not applied yet
	repaint: function() {
		var sel = this.panel.querySelector('select.gg-profile'), picked = sel ? sel.value : null;
		dom.content(this.panel, this.renderPanel(this.status));
		sel = this.panel.querySelector('select.gg-profile');
		if (sel && picked != null && picked != this.status.profile_used)
			sel.value = picked;
	},

	refresh: function() {
		return callStatus().then(L.bind(function(st) {
			this.status = st;
			this.repaint();
			if (this.updateSince && !st.updating && +st.last_update.time > this.updateSince) {
				this.updateSince = 0;
				this.notify(st.last_update.result, st.last_update.message);
			}
		}, this));
	},

	notify: function(result, message) {
		var cls = (result == 'ok') ? 'info' : (result == 'warning') ? 'warning' : 'error';
		ui.addNotification(null, E('p', message), cls);
	},

	run: function(kind, promise) {
		this.busy = kind;
		this.repaint();
		return promise.catch(function(e) { ui.addNotification(null, E('p', e.message), 'error'); })
			.then(L.bind(function() { this.busy = null; return this.refresh(); }, this));
	},

	handleSelect: function(ev) {
		var sel = this.panel.querySelector('select.gg-profile'), profile = sel ? sel.value : '';
		if (!profile) return;
		return this.run('select', callSelect(profile).then(L.bind(function(r) {
			this.notify(r.result, r.message);
		}, this)));
	},

	handleUpdate: function(ev) {
		this.updateSince = +this.status.last_update.time || 1;
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

	renderPanel: function(st) {
		var running = st.running === true, updating = st.updating === true, hasConfig = !!st.profile_used;
		var main = [], facts = [], actions = [];

		if (this.busy == 'select') {
			main.push(E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-warn' }, '●'), ' ', _('Running'), ' ', E('span', { 'class': 'gg-muted' }, _('restarting')) ]));
			main.push(E('p', { 'class': 'gg-sub' }, E('span', { 'class': 'spinning' }, _('Applying the profile… connections drop for a few seconds.'))));
		}
		else if (!st.configured) {
			main.push(E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-muted' }, '●'), ' ', _('Not configured') ]));
			main.push(E('p', { 'class': 'gg-sub' }, _('Add your subscription URL in Settings and save. gatygo downloads the subscription, picks the first profile and starts the tunnel.')));
		}
		else if (running) {
			main.push(E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-ok' }, '●'), ' ', _('Running'), ' ',
				E('span', { 'class': 'gg-muted' }, (st.uptime != null) ? _('for %s').format(fmtDuration(st.uptime)) : '') ]));
			main.push(E('p', { 'class': 'gg-sub' }, [ _('Profile'), ' ', E('strong', {}, st.profile_used || '—') ]));
			if (updating || this.busy == 'update')
				main.push(E('p', { 'class': 'gg-sub' }, E('span', { 'class': 'spinning' }, _('Updating the subscription…'))));
			else if (st.last_update.result == 'error')
				main.push(E('p', { 'class': 'gg-sub gg-warn' }, _('Update failed %s. Still using the previous configuration.').format(fmtAgo(+st.last_update.time))));
			else
				main.push(E('p', { 'class': 'gg-sub' }, [
					st.last_update.time ? _('Updated %s.').format(fmtAgo(+st.last_update.time)) : '',
					st.next_update ? ' ' + _('Next update in %s.').format(fmtIn(st.next_update)) : '' ]));
		}
		else if (!hasConfig) {
			main.push(E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-muted' }, '●'), ' ', _('Stopped'), ' ', E('span', { 'class': 'gg-muted' }, _('no configuration yet')) ]));
			main.push(E('p', { 'class': 'gg-sub' }, _('The subscription has not been downloaded yet, so there is nothing to run. LAN traffic goes directly to the internet.')));
		}
		else {
			main.push(E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-muted' }, '●'), ' ', _('Stopped') ]));
			main.push(E('p', { 'class': 'gg-sub' }, _('LAN traffic goes directly to the internet. The last configuration is kept; Start uses it right away.')));
			if (st.enabled)
				main.push(E('p', { 'class': 'gg-sub' }, _('Autostart is on: the tunnel comes back after a reboot unless you disable it in Settings.')));
		}

		if (st.title) facts.push(E('dt', {}, _('Subscription')), E('dd', {}, st.title));
		if (st.userinfo && (st.userinfo.upload || st.userinfo.download)) {
			var used = (+st.userinfo.upload || 0) + (+st.userinfo.download || 0), total = +st.userinfo.total || 0;
			facts.push(E('dt', {}, _('Traffic')), E('dd', {}, total ? _('%s of %s used').format(fmtBytes(used), fmtBytes(total)) : _('%s used, no limit').format(fmtBytes(used))));
		}
		if (st.userinfo && +st.userinfo.expire) {
			var exp = +st.userinfo.expire, days = Math.floor((exp - Date.now() / 1000) / 86400);
			facts.push(E('dt', {}, _('Expires')), E('dd', {}, new Date(exp * 1000).toLocaleDateString() + ', ' + (days >= 0 ? N_(days, 'in %d day', 'in %d days').format(days) : _('expired'))));
		}
		if (!running && hasConfig && st.profile_used) facts.push(E('dt', {}, _('Last profile')), E('dd', {}, st.profile_used));

		// E() writes every non-null attribute, so a boolean false would still disable the control
		var dis = (!!this.busy || updating) ? '' : null;
		if (st.configured && hasConfig && Array.isArray(st.profiles) && st.profiles.length) {
			actions.push(E('span', { 'class': 'gg-actions' }, [
				E('select', { 'class': 'cbi-input-select gg-profile', 'disabled': dis }, st.profiles.map(function(p) {
					return E('option', { 'value': p.remarks, 'selected': (p.remarks == st.profile_used) ? '' : null, 'title': p.description || '' },
						p.balanced ? p.remarks : p.remarks + ' ' + _('(single server)'));
				})),
				E('button', { 'class': 'cbi-button cbi-button-apply', 'disabled': dis, 'click': ui.createHandlerFn(this, 'handleSelect') }, _('Apply'))
			]));
		}
		if (st.configured)
			actions.push(E('button', { 'class': 'cbi-button cbi-button-action', 'disabled': dis, 'click': ui.createHandlerFn(this, 'handleUpdate') }, _('Update now')));
		if (running) {
			actions.push(E('button', { 'class': 'cbi-button cbi-button-neutral', 'disabled': dis, 'click': ui.createHandlerFn(this, 'handleInit', 'restart') }, _('Restart')));
			actions.push(E('button', { 'class': 'cbi-button cbi-button-negative', 'disabled': dis, 'click': ui.createHandlerFn(this, 'handleInit', 'stop') }, _('Stop')));
		}
		else if (st.configured && hasConfig) {
			actions.push(E('button', { 'class': 'cbi-button cbi-button-apply', 'disabled': dis, 'click': ui.createHandlerFn(this, 'handleInit', 'start') }, _('Start')));
		}

		var alerts = [];
		if (st.last_update.result == 'error' && st.last_update.message)
			alerts.push(E('div', { 'class': 'alert-message error' }, st.last_update.message));
		else if (st.last_update.result == 'warning' && st.last_update.message)
			alerts.push(E('div', { 'class': 'alert-message warning' }, st.last_update.message));
		if (st.announce)
			alerts.push(E('div', { 'class': 'alert-message notice' }, [ st.title ? E('strong', {}, st.title + ': ') : '', st.announce ]));

		return [
			E('div', { 'class': 'gg-status' }, [
				E('div', { 'class': 'gg-main' }, main),
				facts.length ? E('dl', { 'class': 'gg-facts' }, facts) : '',
				E('div', { 'class': 'gg-actions' }, actions)
			])
		].concat(alerts);
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
		this.status = st;
		this.panel = E('div', {});
		dom.content(this.panel, this.renderPanel(st));

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
				' ', E('span', { 'class': 'gg-muted' }, _('Last 200 lines of /var/log/gatygo.log'))
			])
		]);
		var settingsPane = E('div', { 'data-tab': 'settings', 'data-tab-title': _('Settings') },
			haveUci ? [] : [ E('div', { 'class': 'alert-message notice' }, _('Your account cannot read the gatygo settings.')) ]);

		var tabs = E('div', {}, [ settingsPane, this.nodesPane, logPane ]);
		var page = E('div', {}, [ E('style', {}, CSS), E('h2', {}, 'gatygo'), this.panel, tabs ]);

		var self = this;
		return (haveUci ? this.renderSettings(st) : Promise.resolve(null)).then(function(formNode) {
			if (formNode) settingsPane.appendChild(formNode);
			ui.tabs.initTabGroup(tabs.childNodes);
			poll.add(L.bind(self.refresh, self), 5);
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
