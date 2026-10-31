'use strict';
'require view';
'require dom';
'require poll';
'require rpc';
'require uci';
'require ui';

// The main page: one block. The connection state with the country in it and the on/off and
// update buttons, the subscription facts, whether the usual services open through the tunnel,
// and every profile of the subscription as a button with its response time. Settings and the log
// live on the Advanced page behind the gear.

var callStatus = rpc.declare({ object: 'gatygo', method: 'status', expect: { } });
var callUpdate = rpc.declare({ object: 'gatygo', method: 'update', expect: { started: false } });
var callSelect = rpc.declare({ object: 'gatygo', method: 'select', params: [ 'profile' ], expect: { } });
var callConnect = rpc.declare({ object: 'gatygo', method: 'connect', params: [ 'url' ], expect: { } });
var callCheck = rpc.declare({ object: 'gatygo', method: 'check', params: [ 'fresh' ], expect: { } });
var callPing = rpc.declare({ object: 'gatygo', method: 'ping', params: [ 'fresh' ], expect: { } });
var callInitAction = rpc.declare({ object: 'luci', method: 'setInitAction', params: [ 'name', 'action' ], expect: { result: false } });
var callUpgrade = rpc.declare({ object: 'gatygo', method: 'upgrade', params: [ 'action' ], expect: { } });

var CSS = [
	'.gg { --gg-ink:var(--text-color-highest); --gg-ink-2:hsl(0 0% 32%); --gg-ink-3:hsl(0 0% 45%); --gg-line:hsl(0 0% 86%); --gg-line-2:hsl(0 0% 92%);',
	'  --gg-accent:var(--primary-color-high); --gg-accent-tint:hsl(210 80% 96%); --gg-on:var(--success-color-medium); --gg-off:hsl(0 0% 62%); --gg-bad:hsl(0 72% 50%); --gg-good:hsl(150 60% 27%); --gg-slow:hsl(30 85% 31%);',
	'  --gg-warn-ink:hsl(32 90% 26%); --gg-warn-tint:hsl(42 95% 93%); --gg-warn-line:hsl(40 75% 76%);',
	'  --gg-bad-ink:hsl(0 70% 38%); --gg-bad-tint:hsl(0 85% 96%); --gg-bad-line:hsl(0 65% 84%); --gg-heart:hsl(350 70% 45%); --gg-heart-tint:hsl(350 90% 95%);',
	'  --gg-ease:cubic-bezier(.23,1,.32,1); font-variant-numeric:tabular-nums; min-width:0; overflow-wrap:anywhere; }',
	'[data-darkmode="true"] .gg { --gg-ink-2:hsl(0 0% 74%); --gg-ink-3:hsl(0 0% 62%); --gg-line:hsl(0 0% 27%); --gg-line-2:hsl(0 0% 21%);',
	'  --gg-accent-tint:hsl(210 30% 20%); --gg-off:hsl(0 0% 48%); --gg-bad:hsl(0 75% 58%); --gg-good:hsl(150 45% 62%); --gg-slow:hsl(38 75% 62%);',
	'  --gg-warn-ink:hsl(40 85% 68%); --gg-warn-tint:hsl(38 45% 15%); --gg-warn-line:hsl(38 40% 28%);',
	'  --gg-bad-ink:hsl(0 85% 76%); --gg-bad-tint:hsl(0 40% 16%); --gg-bad-line:hsl(0 40% 30%); --gg-heart:hsl(350 85% 74%); --gg-heart-tint:hsl(350 35% 19%); }',
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
	'@media (hover:hover) and (pointer:fine) { .gg-gear:hover { background:var(--gg-line-2); color:var(--gg-ink); } .gg-gear:hover svg { transform:rotate(60deg); } .gg-chip:not(:disabled):not(.is-on):hover { border-color:var(--gg-ink-3); } .gg-icon-btn:not(:disabled):hover { background:var(--gg-line-2); color:var(--gg-ink); } .gg-donate:hover { filter:brightness(.96) saturate(1.1); } }',
	'.gg-gear:active { transform:scale(.94); }',
	'.gg-gear:focus-visible, .gg-chip:focus-visible, .gg-icon-btn:focus-visible, .gg-donate:focus-visible, .gg .cbi-button:focus-visible { outline:2px solid var(--gg-accent); outline-offset:2px; }',
	'.gg-alert { display:flex; align-items:flex-start; gap:12px; margin-top:16px; padding:12px 14px; border:1px solid var(--gg-warn-line); border-radius:6px; background:var(--gg-warn-tint); }',
	'.gg-alert.bad { border-color:var(--gg-bad-line); background:var(--gg-bad-tint); }',
	'.gg-alert-icon { flex:none; margin-top:1px; color:var(--gg-warn-ink); }',
	'.gg-alert.bad .gg-alert-icon { color:var(--gg-bad-ink); }',
	'.gg-alert.good { border-color:color-mix(in srgb, var(--gg-on) 40%, transparent); background:color-mix(in srgb, var(--gg-on) 10%, transparent); }',
	'.gg-alert.good .gg-alert-icon { color:var(--gg-good); }',
	'.gg-alert-body { flex:1 1 0; min-width:0; }',
	'.gg-alert-title { margin:0; font-size:14px; line-height:1.4; font-weight:600; color:var(--gg-ink); }',
	'.gg-alert-text { margin:2px 0 0; max-width:80ch; font-size:13px; line-height:1.5; color:var(--gg-ink-2); }',
	'.gg-detail { margin:6px 0 0; font:12px/1.5 monospace; color:var(--gg-ink-2); white-space:pre-wrap; }',
	'.gg-alert-actions { flex:none; align-self:center; }',
	'.gg-alert-actions a { text-decoration:none; } .gg-alert-actions .cbi-button + .cbi-button { margin-left:8px; }',
	'.gg-steps { margin:4px 0 10px; padding:0; list-style:none; font-size:13px; line-height:1.5; }',
	'.gg-step { display:flex; align-items:center; gap:8px; padding:2px 0; color:var(--gg-ink-3); }',
	'.gg-step.ok, .gg-step.skip, .gg-step.warn { color:var(--gg-ink); } .gg-step.now { color:var(--gg-ink); font-weight:600; } .gg-step.fail { color:var(--gg-bad-ink); font-weight:600; }',
	'.gg-step-ic { flex:none; display:grid; place-items:center; box-sizing:border-box; width:16px; height:16px; border-radius:50%; font-size:10px; font-weight:800; line-height:1; color:#fff; }',
	'.gg-step.ok .gg-step-ic { background:var(--gg-on); } .gg-step.warn .gg-step-ic { background:var(--warn-color-high); } .gg-step.fail .gg-step-ic { background:var(--gg-bad); }',
	'.gg-step.now .gg-step-ic { border:2px solid var(--warn-color-high); border-right-color:transparent; animation:gg-spin .8s linear infinite; }',
	'.gg-step.todo .gg-step-ic { border:1.5px solid var(--gg-off); } .gg-step.skip .gg-step-ic { border:1.5px dashed var(--gg-ink-3); }',
	'.gg-step-note { font-weight:400; color:var(--gg-ink-2); }',
	'.gg-card-check { display:grid; grid-template-columns:minmax(0,1fr) auto; align-items:center; gap:4px 24px; margin-top:20px; padding-top:16px; border-top:1px solid var(--gg-line); }',
	'.gg-checks { display:flex; flex-wrap:wrap; gap:6px 8px; margin:0; padding:0; list-style:none; }',
	'.gg-check { display:inline-flex; align-items:center; gap:7px; padding:3px 9px 3px 4px; border:1px solid var(--gg-line); border-radius:7px; background:var(--background-color-high); font-size:13px; line-height:1.5; color:var(--gg-ink); }',
	'.gg-check.is-none { border-style:dashed; }',
	'.gg-badge { display:grid; place-items:center; flex:none; width:20px; height:20px; border-radius:5px; background:color-mix(in srgb, var(--brand) 14%, transparent); color:var(--brand); }',
	'.gg-check.is-none .gg-badge, .gg-check.is-wait .gg-badge { background:var(--gg-line-2); color:var(--gg-ink-3); }',
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
	'.gg-chip.is-busy:not(.has-ms) { padding-right:34px; }',
	'.gg-chip.is-busy:not(.has-ms)::after { content:""; position:absolute; right:12px; width:12px; height:12px; border-radius:50%; border:2px solid var(--gg-accent); border-right-color:transparent; animation:gg-spin .7s linear infinite; }',
	'@keyframes gg-spin { to { transform:rotate(360deg); } }',
	'.gg-chip.has-ms { padding-right:12px; } .gg-chip-name { min-width:0; }',
	'.gg-chip-ms { display:inline-flex; align-items:center; justify-content:flex-end; min-width:40px; margin-left:2px; font-size:12px; font-weight:400; color:var(--gg-ink-3); }',
	'.gg-chip-ms.good { color:var(--gg-good); } .gg-chip-ms.slow { color:var(--gg-slow); }',
	'.gg-chip-ms.wait::before { content:""; width:30px; height:8px; border-radius:4px; background:linear-gradient(90deg, var(--gg-line-2) 25%, var(--gg-line) 50%, var(--gg-line-2) 75%) 0 0 / 200% 100%; animation:gg-shimmer 1.1s linear infinite; }',
	'.gg-chip.is-busy .gg-chip-ms { position:relative; color:transparent; } .gg-chip.is-busy .gg-chip-ms.wait::before { display:none; }',
	'.gg-chip.is-busy .gg-chip-ms::after { content:""; position:absolute; right:0; width:12px; height:12px; border-radius:50%; border:2px solid var(--gg-accent); border-right-color:transparent; animation:gg-spin .7s linear infinite; }',
	'.gg-chips-foot { display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:4px 24px; margin-top:12px; font-size:12px; line-height:1.5; color:var(--gg-ink-2); }',
	'.gg-chips-foot p { margin:0; } .gg-measure { display:inline-flex; align-items:center; gap:6px; } .gg-measure.bad { color:var(--gg-warn-ink); }',
	'.gg-card-foot { display:flex; flex-wrap:wrap; align-items:center; gap:8px 16px; margin-top:18px; padding-top:12px; border-top:1px solid var(--gg-line); }',
	'.gg-actions { display:flex; flex-wrap:wrap; gap:8px; margin-top:14px; }',
	'.gg .cbi-button { transition:transform 120ms var(--gg-ease); }',
	'.gg .cbi-button:not(:disabled):active { transform:scale(.97); }',
	'.gg-sign { margin:0 0 0 auto; font-size:13px; line-height:1.5; color:var(--gg-ink-2); }',
	'.gg-mark { margin-right:7px; vertical-align:middle; }',
	'.gg-sign b { margin-right:6px; font-weight:700; letter-spacing:-.01em; color:var(--gg-ink); }',
	'.gg-upgrade { display:inline-flex; align-items:center; gap:6px; height:26px; margin:0 0 0 10px; padding:0 10px; border:1px solid var(--gg-warn-line); border-radius:6px; background:var(--gg-warn-tint); color:var(--gg-warn-ink); font:inherit; font-size:12px; font-weight:600; line-height:1; white-space:nowrap; vertical-align:middle; cursor:pointer; transition:transform 120ms var(--gg-ease); }',
	'.gg-upgrade:not(:disabled):active { transform:scale(.97); } .gg-upgrade:disabled { cursor:default; opacity:.6; } .gg-upgrade:focus-visible { outline:2px solid var(--gg-accent); outline-offset:2px; }',
	'.gg-upgrade-sep { width:1px; align-self:stretch; margin:0 2px; background:currentColor; opacity:.3; } .gg-upgrade-v { font-weight:400; opacity:.75; }',
	'.gg-donate { display:inline-flex; align-items:center; gap:6px; height:26px; padding:0 9px 0 8px; border-radius:13px; background:var(--gg-heart-tint); color:var(--gg-heart); font-size:13px; font-weight:600; line-height:1; white-space:nowrap; text-decoration:none; transition:filter 150ms var(--gg-ease), transform 120ms var(--gg-ease); }',
	'.gg-donate:hover { color:var(--gg-heart); text-decoration:none; } .gg-donate:active { transform:scale(.97); } .gg-donate .gg-ext { opacity:.7; }',
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
	'  .gg-checks { display:grid; grid-template-columns:1fr 1fr; gap:6px 8px; } .gg-check-ms { margin-left:auto; justify-content:flex-end; } }',
	'@media (max-width:640px) {',
	'  .gg-card { padding:16px 16px 20px; }',
	'  .gg-checks { grid-template-columns:1fr; } .gg-check { padding-right:10px; } .gg-check-name, .gg-check-ms { white-space:nowrap; }',
	'  .gg-state { font-size:20px; } .gg-state-sep { display:none; } .gg-state-country { flex-basis:100%; order:3; }',
	'  .gg-chips { flex-direction:column; gap:6px; } .gg-chip { height:44px; } .gg-chip-name { flex:1 1 0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; text-align:left; }',
	'  .gg-gear { width:44px; height:44px; }',
	'  .gg-alert { flex-wrap:wrap; } .gg-alert-body { flex-basis:calc(100% - 32px); } .gg-alert-actions { flex-basis:100%; padding-left:32px; }',
	'  .gg-actions .cbi-button { flex:1 1 auto; }',
	'  .gg-field { flex-direction:column; align-items:stretch; } .gg-field input { width:auto; flex:none; }',
	'  .gg-upgrade { display:flex; width:fit-content; margin:6px 0 0 auto; } }',
	'@media (prefers-reduced-motion:reduce) { .gg *, .gg *::after { transition-duration:0ms !important; } .gg-dot.warn, .gg-check-ms.wait::before, .gg-chip-ms.wait::before, .gg-step.now .gg-step-ic { animation:none; } .gg-gear:hover svg { transform:none; } }'
].join('\n');

// Tabler icons (MIT). width/height are attributes: an icon never grows when the styles are missing.
var ICONS = {
	gear: [ 18, 1.8, 'M10.325 4.317c.426 -1.756 2.924 -1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543 -.94 3.31 .826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756 .426 1.756 2.924 0 3.35a1.724 1.724 0 0 0 -1.066 2.573c.94 1.543 -.826 3.31 -2.37 2.37a1.724 1.724 0 0 0 -2.572 1.065c-.426 1.756 -2.924 1.756 -3.35 0a1.724 1.724 0 0 0 -2.573 -1.066c-1.543 .94 -3.31 -.826 -2.37 -2.37a1.724 1.724 0 0 0 -1.065 -2.572c-1.756 -.426 -1.756 -2.924 0 -3.35a1.724 1.724 0 0 0 1.066 -2.573c-.94 -1.543 .826 -3.31 2.37 -2.37c1 .608 2.296 .07 2.572 -1.065', 'M9 12a3 3 0 1 0 6 0a3 3 0 0 0 -6 0' ],
	warn: [ 20, 2, 'M12 9v4', 'M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0', 'M12 16h.01' ],
	bad: [ 20, 2, 'M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0', 'M12 8v4', 'M12 16h.01' ],
	refresh: [ 15, 2, 'M20 11a8.1 8.1 0 0 0 -15.5 -2m-.5 -4v4h4', 'M4 13a8.1 8.1 0 0 0 15.5 2m.5 4v-4h-4' ],
	youtube: [ 13, 1.9, 'M2 8a4 4 0 0 1 4 -4h12a4 4 0 0 1 4 4v8a4 4 0 0 1 -4 4h-12a4 4 0 0 1 -4 -4v-8', 'M10 9l5 3l-5 3l0 -6' ],
	instagram: [ 13, 1.9, 'M4 8a4 4 0 0 1 4 -4h8a4 4 0 0 1 4 4v8a4 4 0 0 1 -4 4h-8a4 4 0 0 1 -4 -4l0 -8', 'M9 12a3 3 0 1 0 6 0a3 3 0 0 0 -6 0', 'M16.5 7.5v.01' ],
	telegram: [ 13, 1.9, 'M15 10l-4 4l6 6l4 -16l-18 7l4 2l2 6l3 -4' ],
	whatsapp: [ 13, 1.9, 'M3 21l1.65 -3.8a9 9 0 1 1 3.4 2.9l-5.05 .9', 'M9 10a.5 .5 0 0 0 1 0v-1a.5 .5 0 0 0 -1 0v1a5 5 0 0 0 5 5h1a.5 .5 0 0 0 0 -1h-1a.5 .5 0 0 0 0 1' ],
	world: [ 13, 1.9, 'M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0', 'M3.6 9h16.8', 'M3.6 15h16.8', 'M11.5 3a17 17 0 0 0 0 18', 'M12.5 3a17 17 0 0 1 0 18' ],
	download: [ 13, 2.2, 'M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2 -2v-2', 'M7 11l5 5l5 -5', 'M12 4l0 12' ],
	upgrade: [ 20, 2, 'M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2 -2v-2', 'M7 11l5 5l5 -5', 'M12 4l0 12' ],
	check: [ 20, 2, 'M5 12l5 5l10 -10' ],
	heart: [ 13, 2.2, 'M19.5 12.572l-7.5 7.428l-7.5 -7.428a5 5 0 1 1 7.5 -6.566a5 5 0 1 1 7.5 6.572' ],
	arrow: [ 12, 2.2, 'M17 7l-10 10', 'M8 7l9 0l0 9' ]
};

// The services check shows each service with its brand icon on a tint of its colour; a service
// gatygo does not know gets the world.
var BRANDS = {
	youtube: [ 'youtube', '#ff0000' ], instagram: [ 'instagram', '#e4405f' ], telegram: [ 'telegram', '#26a5e4' ], whatsapp: [ 'whatsapp', '#25d366' ]
};

function brand(name) {
	return BRANDS[String(name).toLowerCase().replace(/\s+/g, '')] || [ 'world', 'var(--gg-ink-2)' ];
}

function icon(name, cls) {
	var i = ICONS[name], ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg');
	var attrs = { 'width': i[0], 'height': i[0], 'viewBox': '0 0 24 24', 'fill': 'none', 'stroke': 'currentColor', 'stroke-width': i[1],
		'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' };
	for (var k in attrs) svg.setAttribute(k, attrs[k]);
	if (cls) svg.setAttribute('class', cls);
	i.slice(2).forEach(function(d) { var p = document.createElementNS(ns, 'path'); p.setAttribute('d', d); svg.appendChild(p); });
	return svg;
}

// The gatygo mark (docs/logo), drawn as the small-size cut: an amber tile, three routes that start
// at different points, merge and leave through the right wall. Centred on the x-height, as in the logo.
function mark() {
	var ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg');
	var el = function(tag, attrs) {
		var n = document.createElementNS(ns, tag);
		for (var k in attrs) n.setAttribute(k, attrs[k]);
		return svg.appendChild(n);
	};
	[ [ 'width', 16 ], [ 'height', 16 ], [ 'viewBox', '20 20 216 216' ], [ 'class', 'gg-mark' ], [ 'aria-hidden', 'true' ] ]
		.forEach(function(a) { svg.setAttribute(a[0], a[1]); });
	el('rect', { 'x': 20, 'y': 20, 'width': 216, 'height': 216, 'rx': 52, 'fill': '#ffb020' });
	var line = { 'fill': 'none', 'stroke': '#16181d', 'stroke-width': 32, 'stroke-linecap': 'round' };
	[ 'M104 72H114C143 72 143 128 172 128', 'M54 184H114C143 184 143 128 172 128', 'M78 128H176' ]
		.forEach(function(d) { line.d = d; el('path', line); });
	line.d = 'M172 128H236'; line['stroke-linecap'] = 'butt';
	el('path', line);
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
	link: null,            // the stored subscription link, shown again in the first-run form after a failed try
	painted: null,         // what the panel was last painted from
	check: null,           // the last services check: {available, tunnel, time, services}
	checking: false,       // a check is running
	checkedTunnel: null,   // the tunnel (profile and xray pid) the last check was started for; null = page just opened
	ping: null,            // the countries' response times: {time, measuring, profiles: [{remarks, ms}]}; null = not asked yet
	pinging: false,        // a ping call is on its way
	upgradeAsk: false,     // the confirmation of an upgrade is open
	upgradeSeen: false,    // this page saw an upgrade run: its end reloads the page (the new version's page)
	upgradeTimer: null,
	panel: null,

	// no form on this page: no Save & Apply footer
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return Promise.all([ callStatus(), L.resolveDefault(uci.load('gatygo'), null) ]);
	},

	// Repaint only when something visible changed (times are shown to the minute), and keep what
	// the user holds: the focused control and a half-typed link.
	repaint: function() {
		var st = this.status;
		var key = JSON.stringify([ st, this.busy, this.busyProfile, this.urlError, this.check, this.checking, this.ping, this.upgradeAsk, Math.floor(Date.now() / 60000) ],
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
			// rpcd restarts while the new packages install: the last progress stays, without a word
			if ((st == null || typeof st != 'object') && this.upgrading()) return this.upgradeTick();
			this.status = st;
			if (this.upgrading()) {
				this.upgradeSeen = true;
				this.upgradeTick();
			}
			else if (this.upgradeSeen && this.upgradeRun().state == 'ok') {
				this.upgradeSeen = false;
				location.reload();
				return;
			}
			this.syncCheck();
			this.syncPing();
			this.repaint();
		}, this), L.bind(function(e) {
			if (!this.upgrading()) throw e;
			this.upgradeTick();
		}, this));
	},

	// the progress of an upgrade ($GATYGO_RUN/upgrade.json), {} when there is none
	upgradeRun: function() {
		return (this.status && this.status.upgrade && this.status.upgrade.run) || {};
	},

	upgrading: function() {
		return this.upgradeRun().state == 'running';
	},

	// while an upgrade runs the page asks every 2 s
	upgradeTick: function() {
		if (this.upgradeTimer) return;
		this.upgradeTimer = window.setTimeout(L.bind(function() { this.upgradeTimer = null; this.refresh(); }, this), 2000);
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

	// The response times belong to the subscription, not to the tunnel. Asked for once there are
	// countries to show: the daemon answers at once with what it has and measures again by itself
	// when that is older than 5 minutes. While it measures, the page asks again.
	syncPing: function() {
		if (this.ping == null && !this.pinging && this.status.profile_used) this.runPing(false);
	},

	runPing: function(fresh) {
		if (this.pinging) return;
		this.pinging = true;
		// a daemon from before there was a ping: no times, and no asking again
		return callPing(!!fresh).then(L.bind(function(r) { this.ping = r; }, this), L.bind(function() { this.ping = {}; }, this))
			.then(L.bind(function() {
				this.pinging = false;
				if (this.ping.measuring === true) window.setTimeout(L.bind(this.runPing, this, false), 2000);
				this.repaint();
			}, this));
	},

	handlePing: function(ev) {
		return this.runPing(true);
	},

	run: function(kind, promise) {
		this.busy = kind;
		this.repaint();
		return promise.catch(function(e) { ui.addNotification(null, E('p', {}, [ e.message ]), 'error'); })
			.then(L.bind(function() { this.busy = null; this.busyProfile = null; return this.refresh(); }, this));
	},

	handleSelect: function(profile, ev) {
		// the country in use: nothing to switch, unless the saved one is another (gone from the
		// subscription, or a switch to it failed)
		var st = this.status;
		if (profile == st.profile_used && (!st.profile || st.profile == st.profile_used)) return;
		this.busyProfile = profile;
		return this.run('select', callSelect(profile).then(function(r) {
			if (r && r.result == 'busy')
				ui.addNotification(null, E('p', _('An update is running. Try again in a minute.')), 'warning');
		}));
	},

	handleUpdate: function(ev) {
		return this.run('update', callUpdate().then(function(started) {
			if (!started)
				ui.addNotification(null, E('p', _('An update is already running.')), 'warning');
		}));
	},

	handleUpgradeAsk: function(ev) {
		this.upgradeAsk = true;
		this.repaint();
		// the button is at the foot of the card, the confirmation under the status
		var ask = this.panel.querySelector('[data-key="up-start"]');
		if (ask) ask.closest('.gg-alert').scrollIntoView({ block: 'nearest', behavior: 'smooth' });
	},

	handleUpgradeCancel: function(ev) {
		this.upgradeAsk = false;
		this.repaint();
	},

	// the router upgrades by itself: the page follows its progress from the status
	handleUpgradeStart: function(ev) {
		this.upgradeAsk = false;
		return this.run('upgrade', callUpgrade('start').then(function() {
			// the run writes its first step a moment after the start
			return new Promise(function(resolve) { window.setTimeout(resolve, 1500); });
		}));
	},

	handleUpgradeDismiss: function(ev) {
		return this.run('upgrade', callUpgrade('dismiss'));
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
		this.link = url;
		return this.run('connect', callConnect(url).then(function(r) {
			if (r.error) throw new Error(r.error);
			// the download shows up in the status a moment after the start
			return new Promise(function(resolve) { window.setTimeout(resolve, 3000); });
		}));
	},

	// What went wrong, in the user's words. The daemon's own message goes below as the detail.
	problem: function(st, running) {
		var info = st.userinfo || {}, ls = st.last_select || {};
		// a failed switch goes first: it is the latest thing done here; a failed update shows again after it
		var lu = (ls.result == 'error' || ls.result == 'warning') ? ls : (st.last_update || {});
		var exp = +info.expire || 0, total = +info.total || 0, used = (+info.upload || 0) + (+info.download || 0);
		var kept = running ? ' ' + _('You stay connected with the previous settings.') : '';
		var retry = { label: _('Try again'), handler: 'handleUpdate' };

		// xray quit and procd no longer restarts it (or is about to). What the home network has now
		// is the "If the VPN stops by itself" setting: no way out (the firewall rules stay), or the
		// regular internet (the daemon took them back and says so in st.crash.direct). The daemon
		// also notes the moment and the last lines of xray's log.
		if (!running && st.crashed != null) {
			var crash = st.crash || {}, direct = (crash.direct === true);
			return { bad: !direct, crashed: true, state: _('Stopped by itself'),
				title: crash.time ? _('The VPN stopped by itself %s').format(fmtAgo(+crash.time)) : _('The VPN stopped by itself'),
				text: direct ? _('Devices at home use the regular internet since then: what needs the VPN does not open. Press Start to try again.')
					: _('Devices at home have no internet now. Press Start to try again, or turn the VPN off to use the regular internet.'),
				detail: [ (st.crashed == 137) ? _('xray was killed (exit code 137), most often because the router ran out of memory')
					: _('xray exit code %d').format(st.crashed), crash.log ].filter(Boolean).join('\n'),
				action: { label: _('Turn off'), handler: 'handleInit', arg: 'stop' } };
		}
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
		case 'core_failed':
			p.title = _('Couldn’t download the VPN engine');
			p.text = _('gatygo downloads it from GitHub once after it is installed or updated. Check the router’s internet connection, then try again.');
			p.action = retry;
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
				// as text, never as HTML: country names, messages and xray's log come from outside
				E('p', { 'class': 'gg-alert-title' }, [ p.title ]),
				p.text ? E('p', { 'class': 'gg-alert-text' }, [ p.text ]) : '',
				p.detail ? E('p', { 'class': 'gg-detail' }, [ p.detail ]) : ''
			]),
			action ? E('div', { 'class': 'gg-alert-actions' }, action) : ''
		]);
	},

	// Why an upgrade failed, in the user's words; args fill in the numbers and names
	upgradeReason: function(run) {
		var a = Array.isArray(run.args) ? run.args : [];
		switch (run.code) {
		case 'busy': return _('Another action is running: a subscription update or a country switch. Try again in a minute.');
		case 'no_release': return _('GitHub did not give the new version.');
		case 'no_rollback': return _('The current version is not on GitHub: there would be nothing to go back to.');
		case 'openwrt': return _('gatygo needs OpenWrt 25.12, the router runs %s.').format(a[0] || '');
		case 'conflict': return _('%s is installed: it owns the same proxy rules. Remove it first.').format(a[0] || '');
		case 'no_core': return _('The new version has no xray core for this router\'s processor.');
		case 'no_space': return _('Not enough flash: %d MB needed, %d MB free.').format(+a[0] || 0, +a[1] || 0);
		case 'no_memory': return _('Not enough memory: %d MB needed, %d MB free.').format(+a[0] || 0, +a[1] || 0);
		case 'download_failed': return _('The packages could not be downloaded.');
		case 'checksum': return _('A downloaded file is damaged: its checksum does not match.');
		case 'deps': return _('The router\'s package feeds do not have: %s.').format(a[0] || '');
		case 'install_failed': return _('The packages did not install.');
		case 'core_failed': return _('The xray core did not install.');
		case 'config_failed': return _('The new version could not build the settings from the subscription.');
		case 'not_started': return _('The new version did not start.');
		case 'rollback_failed': return _('The previous version could not be put back. Reinstall gatygo with install.sh.');
		case 'interrupted': return _('The update stopped halfway. If the VPN does not work, reinstall gatygo with install.sh.');
		}
		return '';
	},

	// An upgrade's panel under the status: the confirmation, the failure, or a fresh success
	// (the first 5 minutes after it, on the new version's page)
	renderUpgrade: function(up, dis) {
		var run = up.run || {}, steps = run.steps || {};
		var button = L.bind(function(cls, label, handler, key) {
			return E('button', { 'class': 'cbi-button ' + cls, 'type': 'button', 'disabled': dis, 'data-key': key, 'click': ui.createHandlerFn(this, handler) }, label);
		}, this);
		var panel = function(kind, ic, title, text, actions) {
			return E('div', { 'class': 'gg-alert' + (kind ? ' ' + kind : ''), 'role': (kind == 'bad') ? 'alert' : 'status' }, [
				icon(ic, 'gg-alert-icon'),
				E('div', { 'class': 'gg-alert-body' }, [
					E('p', { 'class': 'gg-alert-title' }, [ title ]),
					text ? E('p', { 'class': 'gg-alert-text' }, [ text ]) : ''
				]),
				actions ? E('div', { 'class': 'gg-alert-actions' }, actions) : ''
			]);
		};
		if (this.upgradeAsk && up.available && run.state != 'running')
			return panel('', 'upgrade', _('Update to %s?').format(up.latest),
				_('The internet through the VPN drops for a few seconds. The subscription, country, settings and My rules stay.'),
				[ button('cbi-button-neutral', _('Cancel'), 'handleUpgradeCancel', 'up-cancel'), button('cbi-button-action', _('Update'), 'handleUpgradeStart', 'up-start') ]);
		if (run.state == 'failed')
			return panel('bad', 'bad', _('Update failed'),
				[ this.upgradeReason(run), (run.code != 'rollback_failed' && run.code != 'interrupted') ? _('Version %s is running.').format(run.from) : '' ].filter(String).join(' '),
				[ button('cbi-button-neutral', _('Close'), 'handleUpgradeDismiss', 'up-close'), button('cbi-button-action', _('Try again'), 'handleUpgradeStart', 'up-retry') ]);
		if (run.state == 'ok' && Date.now() / 1000 - (+run.time || 0) <= 300)
			return panel('good', 'check', _('Updated to %s').format(run.to),
				(steps.core == 'warn') ? _('xray core') + ' — ' + _('not downloaded, the current one works; retried with the next subscription update') : '');
		return '';
	},

	// the five steps of a running upgrade, each with its mark
	renderSteps: function(run) {
		var steps = run.steps || {};
		return E('ul', { 'class': 'gg-steps', 'aria-live': 'polite' }, [
			[ 'check', _('Checking the router') ], [ 'download', _('Downloading') ], [ 'install', _('Installing') ],
			[ 'core', _('xray core') ], [ 'restart', _('Restarting the VPN and checking') ]
		].map(function(s) {
			var v = steps[s[0]];
			if ([ 'todo', 'now', 'ok', 'skip', 'warn', 'fail' ].indexOf(v) < 0) v = 'todo';
			var note = (v == 'skip') ? _('unchanged') : (v == 'warn') ? _('not downloaded, the current one works; retried with the next subscription update') : '';
			return E('li', { 'class': 'gg-step ' + v }, [
				E('span', { 'class': 'gg-step-ic', 'aria-hidden': 'true' }, (v == 'ok') ? '✓' : (v == 'warn' || v == 'fail') ? '!' : ''),
				s[1], note ? E('span', { 'class': 'gg-step-note' }, ' — ' + note) : '' ]);
		}));
	},

	// Do the usual services open through the tunnel? A tile per service with its brand icon; the
	// number says how fast (the time to the end of the TLS handshake) and its colour how good,
	// a dashed tile with a grey icon did not answer. Plain items: only ↻ is a button. When nothing
	// opens, another country is suggested only if one answers (silent: none does, the line under
	// the countries says so; others: another one does).
	renderCheck: function(silent, others) {
		var c = this.check, busy = this.checking;
		if (!c || !c.available || !Array.isArray(c.services) || !c.services.length) return '';
		var items = c.services.map(function(sv) {
			var ms = sv.ms, st = busy ? 'wait' : (ms == null) ? 'none' : 'ok', b = brand(sv.name);
			return E('li', { 'class': 'gg-check is-' + st, 'style': '--brand:' + b[1] }, [ E('span', { 'class': 'gg-badge' }, icon(b[0])), E('span', { 'class': 'gg-check-name' }, [ sv.name ]),
				E('span', { 'class': 'gg-check-ms ' + (busy ? 'wait' : ms == null ? 'none' : ms < 1000 ? 'good' : ms < 2000 ? 'slow' : 'bad') },
					busy ? '' : (ms == null) ? _('no reply') : (ms < 1000) ? _('%d ms').format(ms) : _('%s s').format((ms / 1000).toFixed(1))) ]);
		});
		var none = !busy && c.services.every(function(sv) { return sv.ms == null; });
		return E('div', { 'class': 'gg-card-check' }, [
			E('ul', { 'class': 'gg-checks', 'title': _('Checked through the VPN'), 'aria-live': 'polite' }, items),
			E('p', { 'class': 'gg-checked' }, [ busy ? _('Checking…') : _('Checked %s').format(fmtAgo(+c.time)),
				E('button', { 'class': 'gg-icon-btn', 'type': 'button', 'disabled': busy ? '' : null, 'title': _('Check again'), 'aria-label': _('Check again'),
					'data-key': 'recheck', 'click': ui.createHandlerFn(this, 'handleCheck') }, icon('refresh')) ]),
			(none && !silent) ? E('p', { 'class': 'gg-check-hint' }, others ? _('Nothing opens through this country. Try another one.')
				: _('Nothing opens through this country.')) : ''
		]);
	},

	// the first-run form: paste the link, press Connect. After a failed try the stored link stays
	// in the field and the button says Update: fix the link or the settings and try again
	renderSetup: function(st, dis) {
		var lu = st.last_update || {}, failed = st.configured && lu.result == 'error', error = this.urlError, detail = null;
		if (!error && failed) {
			detail = lu.message;
			error = (lu.code == 'fetch_failed') ? _('This link did not work. Check that you copied the whole link from your provider.')
				: (lu.code == 'not_recognised') ? _('The server answered, but not with a list of countries. Ask your provider whether routers are supported, or change User agent in Settings (the gear).')
				: (lu.code == 'device_limit') ? _('Too many devices on this subscription. Remove a device in your provider’s account and try again.')
				: (lu.code == 'core_failed') ? _('gatygo could not download the VPN engine from GitHub. Check the router’s internet connection and try again.')
				: _('gatygo could not set up the connection.');
		}
		return [
			E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-dot' }), _('Not set up yet') ]),
			E('p', { 'class': 'gg-meta' }, _('Paste the subscription link from your VPN provider. gatygo downloads the list of countries and connects your whole home network.')),
			E('form', { 'class': 'gg-field' + (error ? ' is-bad' : ''), 'novalidate': '', 'submit': ui.createHandlerFn(this, 'handleConnect') }, [
				E('input', { 'class': 'cbi-input-text gg-url', 'type': 'url', 'placeholder': 'https://', 'aria-label': _('Subscription link'), 'autocomplete': 'off', 'data-key': 'url', 'value': failed ? this.link : null }),
				E('button', { 'class': 'cbi-button cbi-button-action important', 'type': 'submit', 'disabled': dis, 'data-key': 'connect' }, failed ? _('Update') : _('Connect'))
			]),
			error ? E('p', { 'class': 'gg-field-error' }, [ error ]) : '',
			detail ? E('p', { 'class': 'gg-detail' }, [ detail ]) : ''
		];
	},

	renderPanel: function(st) {
		var running = st.running === true, updating = st.updating === true, hasConfig = !!st.profile_used;
		var profiles = Array.isArray(st.profiles) ? st.profiles : [], lu = st.last_update || {};
		var up = st.upgrade || {}, upgrading = (up.run && up.run.state == 'running');
		// E() writes every non-null attribute, so a boolean false would still disable the control
		var dis = (!!this.busy || updating || upgrading) ? '' : null;
		var problem = (hasConfig && this.busy != 'select' && !upgrading) ? this.problem(st, running) : null;
		var main = [], facts = [];

		if (upgrading) {
			main.push(E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-dot warn' }), _('Updating'),
				E('span', { 'class': 'gg-state-sep' }, '·'), E('span', { 'class': 'gg-state-country' }, [ up.run.to || '' ]) ]));
			main.push(this.renderSteps(up.run));
			main.push(E('p', { 'class': 'gg-meta' }, _('Countries and buttons are unavailable until the update ends.')));
		}
		else if (!hasConfig && (updating || this.busy == 'connect')) {
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
			var state = (problem && problem.crashed) ? problem.state : null;
			main.push(E('p', { 'class': 'gg-state' }, [ E('span', { 'class': 'gg-dot' + (state ? ' bad' : '') }), state || _('Disconnected'),
				E('span', { 'class': 'gg-state-sep' }, '·'), country(this.busyProfile || st.profile_used, true) ]));
			main.push(E('p', { 'class': 'gg-meta' }, (updating || this.busy == 'update')
				? E('span', { 'class': 'spinning' }, _('Updating the list of countries…'))
				: state ? '' : _('Your home network is using the regular internet. Start connects to the selected country right away.')));
		}

		if (hasConfig) {
			var info = st.userinfo || {}, used = (+info.upload || 0) + (+info.download || 0), total = +info.total || 0, exp = +info.expire || 0;
			if (st.title) facts.push(E('div', {}, [ E('dt', {}, _('Subscription')), E('dd', {}, [ st.title ]) ]));
			if (used || total)
				facts.push(E('div', {}, [ E('dt', {}, _('Traffic')), E('dd', { 'class': (total && used >= total) ? 'bad' : null },
					total ? _('%s of %s used').format(fmtBytes(used), fmtBytes(total)) : _('%s used, no limit').format(fmtBytes(used))) ]));
			if (exp) {
				var days = Math.floor((exp - Date.now() / 1000) / 86400);
				facts.push(E('div', {}, [ E('dt', {}, _('Expires')), E('dd', { 'class': (days < 0) ? 'bad' : null },
					new Date(exp * 1000).toLocaleDateString() + ', ' + (days >= 0 ? N_(days, 'in %d day', 'in %d days').format(days) : _('expired %s').format(fmtAgo(exp)))) ]));
			}
		}

		// the response time of a country: its fastest server, from the router and not through the VPN
		var pg = this.ping || {}, measuring = (pg.measuring === true), times = Object.create(null);
		(Array.isArray(pg.profiles) ? pg.profiles : []).forEach(function(p) { times[p.remarks] = p.ms; });

		var selected = (this.busy == 'select') ? this.busyProfile : st.profile_used;
		var chips = profiles.map(L.bind(function(p) {
			var f = splitFlag(p.remarks), on = (p.remarks == selected), ms = times[p.remarks], hasMs = measuring || (p.remarks in times);
			return E('button', { 'class': 'gg-chip' + (on ? ' is-on' : '') + (on && this.busy == 'select' ? ' is-busy' : '') + (hasMs ? ' has-ms' : ''), 'type': 'button',
				'aria-pressed': on ? 'true' : 'false', 'disabled': dis, 'title': p.description || null,
				'data-key': 'chip:' + p.remarks, 'click': ui.createHandlerFn(this, 'handleSelect', p.remarks) },
				[ f.flag ? E('span', { 'class': 'gg-chip-flag' }, f.flag) : '', E('span', { 'class': 'gg-chip-name' }, [ f.name ]),
					hasMs ? E('span', { 'class': 'gg-chip-ms' + (measuring ? ' wait' : ms == null ? '' : ms <= 60 ? ' good' : ms >= 120 ? ' slow' : ''),
						'title': measuring ? null : (ms == null) ? _('No reply from this server') : _('Response time from your router to this server') },
						measuring ? '' : (ms == null) ? '—' : _('%d ms').format(ms)) : '' ]);
		}, this));

		var measure = '';
		var silent = !measuring && pg.time != null && profiles.length > 0 && profiles.every(function(p) { return times[p.remarks] == null; });
		var others = !measuring && profiles.some(function(p) { return p.remarks != st.profile_used && times[p.remarks] != null; });
		if (measuring || pg.time != null) {
			measure = E('p', { 'class': 'gg-measure' + (silent ? ' bad' : '') }, [
				E('span', {}, measuring ? _('Measuring response time…') : silent ? _('No server answered: your provider has an outage, or the router has no internet.')
					: _('Response time measured %s').format(fmtAgo(+pg.time))),
				E('button', { 'class': 'gg-icon-btn', 'type': 'button', 'disabled': measuring ? '' : null, 'title': _('Measure again'), 'aria-label': _('Measure again'),
					'data-key': 'remeasure', 'click': ui.createHandlerFn(this, 'handlePing') }, icon('refresh')) ]);
		}

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
			this.renderUpgrade(up, dis),
			problem ? this.renderAlert(problem, dis) : '',
			(hasConfig && running && this.busy != 'select') ? this.renderCheck(silent, others) : '',
			(hasConfig && chips.length) ? E('div', { 'class': 'gg-card-pick' }, [
				E('div', { 'class': 'gg-chips', 'role': 'group', 'aria-label': _('Country') }, chips),
				E('div', { 'class': 'gg-chips-foot' }, [
					E('p', {}, running ? _('Tap a country to switch. Connections drop for a few seconds.') : _('Tap a country to choose where Start connects.')),
					measure ])
			]) : '',
			E('div', { 'class': 'gg-card-foot' }, [
				E('a', { 'class': 'gg-donate', 'href': 'https://filatov.page', 'target': '_blank', 'rel': 'noopener', 'data-key': 'donate' }, [ icon('heart'), _('Donate'), icon('arrow', 'gg-ext') ]),
				E('p', { 'class': 'gg-sign' }, [ mark(), E('b', {}, 'gatygo'), st.version || '',
					(up.available && !upgrading) ? E('button', { 'class': 'gg-upgrade', 'type': 'button', 'disabled': dis, 'data-key': 'upgrade',
						'click': ui.createHandlerFn(this, 'handleUpgradeAsk') }, [ icon('download'), _('Update'), E('span', { 'class': 'gg-upgrade-sep' }), E('span', { 'class': 'gg-upgrade-v' }, [ up.latest ]) ]) : '' ])
			])
		]);
	},

	render: function(data) {
		var st = data[0];
		this.status = st;
		this.link = uci.get('gatygo', 'main', 'sub_url') || null;
		this.panel = E('div', {});
		// from the Advanced page's Update button: the confirmation right away
		var q = new URLSearchParams(location.search);
		if (q.get('upgrade') == '1') {
			q.delete('upgrade');
			history.replaceState(null, '', location.pathname + (q.toString() ? '?' + q : '') + location.hash);
			this.upgradeAsk = !!(st.upgrade && st.upgrade.available);
		}
		if (this.upgrading()) {
			this.upgradeSeen = true;
			this.upgradeTick();
		}
		this.syncCheck();
		this.syncPing();
		this.repaint();
		poll.add(L.bind(this.refresh, this), 5);
		return E('div', { 'class': 'gg' }, [ E('style', {}, CSS), E('h2', { 'class': 'gg-sr' }, 'gatygo'), this.panel ]);
	}
});
