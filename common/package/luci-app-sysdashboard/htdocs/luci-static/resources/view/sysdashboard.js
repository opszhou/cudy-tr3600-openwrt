'use strict';
'require poll';
'require rpc';
'require view';

/*
 * RPC note: LuCI's rpc.call(req, cb, nobatch) is the low-level message sender;
 * the (object, method, params) form does NOT exist. rpc.declare() is the
 * public wrapper and is what we use here.
 */
var callSnapshot = rpc.declare({
	object: 'sysdashboard',
	method: 'get'
});

/*
 * 只读仪表盘。数据全部来自单次 rpcd 快照（sysdashboard.get），
 * 速率/CPU 由前端对两次快照做差分，后端无状态、不 sleep、不落盘。
 *
 * 布局参考 5G CPE 类面板的视觉语言（hero + 三列：信号 / 上联 / 流量，
 * 第二行：在线设备 + 速率趋势），样式为自研轻量 CSS，不引入第三方主题。
 */

var POLL_SECONDS = 3;
var HISTORY = 60;

var prev = null;
var prevTs = 0;
var cpuUsage = 0;
var rateRx = 0;
var rateTx = 0;
var rxHistory = [];
var txHistory = [];
var dom = {};

var CSS = [
	'.sd-root { max-width: 1040px; }',
	'.sd-hero { display:flex; align-items:center; gap:12px; flex-wrap:wrap; margin-bottom:10px; }',
	'.sd-hero h3 { margin:0; font-size:18px; }',
	'.sd-pill { display:inline-flex; align-items:center; gap:6px; font-size:12px; padding:2px 10px; border-radius:999px;',
	'  background:rgba(56,168,155,.15); color:#2f9e8f; font-weight:600; }',
	'.sd-pill.off { background:rgba(224,90,79,.15); color:#d3544a; }',
	'.sd-big { font-size:28px; font-weight:700; line-height:1.2; }',
	'.sd-big small { font-size:13px; font-weight:500; opacity:.6; margin-left:3px; }',
	'.sd-sub { opacity:.65; font-size:12px; }',
	'.sd-bars { display:flex; align-items:flex-end; gap:4px; height:34px; margin:8px 0 10px; }',
	'.sd-bars i { flex:1; border-radius:3px; background:rgba(127,127,127,.2); }',
	'.sd-bars i.on { background:linear-gradient(180deg,#5e72e4,#4a90e2); }',
	'.sd-kpis { display:grid; grid-template-columns:repeat(auto-fit,minmax(108px,1fr)); gap:8px; }',
	'.sd-kpi { border:1px solid rgba(127,127,127,.18); border-radius:8px; padding:8px 10px; min-width:0; }',
	'.sd-kpi .sd-sub { font-size:11px; line-height:1.3; }',
	'.sd-kpi b { display:block; font-size:15px; font-weight:600; margin-top:3px; word-break:break-all; }',
	'.sd-sigrow { display:grid; grid-template-columns:minmax(0,230px) minmax(0,1fr); gap:16px; align-items:start; }',
	'@media (max-width:760px) { .sd-sigrow { grid-template-columns:1fr; } }',
	'.sd-tiles { display:grid; grid-template-columns:repeat(auto-fit,minmax(170px,1fr)); gap:8px; margin-bottom:10px; }',
	'.sd-tile { border:1px solid rgba(127,127,127,.18); border-radius:8px; padding:8px; text-align:center; min-width:0; }',
	'.sd-tile b { font-size:12px; display:block; margin-top:2px; word-break:break-all; }',
	'.sd-spark svg { width:100%; height:44px; display:block; }',
	'.sd-chart svg { width:100%; height:150px; display:block; }',
	'.sd-gridline { stroke:rgba(127,127,127,.25); stroke-width:1; stroke-dasharray:4 4; }',
	'.sd-empty { opacity:.6; font-size:12px; padding:8px 0; }',
	'.sd-dot { display:inline-block; width:9px; height:9px; border-radius:50%; margin-right:5px; vertical-align:middle; }',
	'.sd-mini { display:grid; grid-template-columns:repeat(auto-fit,minmax(120px,1fr)); gap:8px; }',
	'.sd-mini > div { border:1px solid rgba(127,127,127,.18); border-radius:8px; padding:8px; text-align:center; }',
	'.sd-foot { margin-top:10px; }'
].join('\n');

function esc(v) {
	return String(v == null ? '' : v).replace(/[&<>"']/g, function(c) {
		return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
	});
}

function humanBytes(n) {
	var units = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
	n = Math.max(0, n || 0);
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	return (i === 0 ? n.toFixed(0) : n.toFixed(1)) + ' ' + units[i];
}

function humanRate(n) { return humanBytes(n) + '/s'; }

function humanUptime(s) {
	s = Math.max(0, s || 0);
	var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
	var out = [];
	if (d) out.push(d + 'd');
	if (h) out.push(h + 'h');
	out.push(m + 'm');
	return out.join(' ');
}

/* 紧凑指标网格：标签在上、数值在下，自适应列数（仪表盘观感，不做全宽行） */
function tiles(rows) {
	var html = '<div class="sd-kpis">';
	for (var i = 0; i < rows.length; i++)
		html += '<div class="sd-kpi"><div class="sd-sub">' + rows[i][0] + '</div><b>' + rows[i][1] + '</b></div>';
	return html + '</div>';
}

function signalLevel(rsrp) {
	if (!rsrp) return { bars: 0, text: _('No signal'), color: '#e05a4f' };
	if (rsrp >= -85) return { bars: 5, text: _('Excellent'), color: '#38a89b' };
	if (rsrp >= -95) return { bars: 4, text: _('Good'), color: '#5aa9d6' };
	if (rsrp >= -105) return { bars: 3, text: _('Fair'), color: '#e2a03f' };
	if (rsrp >= -115) return { bars: 2, text: _('Weak'), color: '#e07b4f' };
	return { bars: 1, text: _('Very weak'), color: '#e05a4f' };
}

function bars(level) {
	var h = [24, 32, 40, 48, 56], html = '<div class="sd-bars">', i;
	for (i = 0; i < 5; i++)
		html += '<i class="' + (i < level ? 'on' : '') + '" style="height:' + h[i] + '%"></i>';
	return html + '</div>';
}

function spark(arr, color) {
	if (!arr || arr.length < 2) return '<div class="sd-empty">—</div>';
	var W = 240, H = 44, P = 3, max = 1, i, pts = [];
	for (i = 0; i < arr.length; i++) max = Math.max(max, arr[i]);
	for (i = 0; i < arr.length; i++) {
		var x = P + (W - 2 * P) * i / (HISTORY - 1);
		var y = H - P - (H - 2 * P) * arr[i] / max;
		pts.push((i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1));
	}
	return '<svg viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="none">' +
		'<path d="' + pts.join(' ') + '" fill="none" stroke="' + color + '" stroke-width="2"/></svg>';
}

function chart(rx, tx) {
	var W = 600, H = 150, P = 6, max = 1, i;
	for (i = 0; i < rx.length; i++) max = Math.max(max, rx[i]);
	for (i = 0; i < tx.length; i++) max = Math.max(max, tx[i]);

	function series(arr, color) {
		if (arr.length < 2) return '';
		var pts = [], x, y, j;
		for (j = 0; j < arr.length; j++) {
			x = P + (W - 2 * P) * j / (HISTORY - 1);
			y = H - P - (H - 2 * P) * arr[j] / max;
			pts.push((j ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1));
		}
		var line = pts.join(' ');
		var lastX = P + (W - 2 * P) * (arr.length - 1) / (HISTORY - 1);
		var area = line + ' L' + lastX.toFixed(1) + ' ' + (H - P) + ' L' + P + ' ' + (H - P) + ' Z';
		return '<path d="' + area + '" fill="' + color + '" opacity="0.14"/>' +
			'<path d="' + line + '" fill="none" stroke="' + color + '" stroke-width="2" stroke-linejoin="round"/>';
	}

	return '<svg viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="none">' +
		'<line class="sd-gridline" x1="0" y1="' + (H / 2) + '" x2="' + W + '" y2="' + (H / 2) + '"/>' +
		series(rx, '#4a90e2') + series(tx, '#7b61c9') + '</svg>';
}

function compute(s) {
	var dt = s.ts - prevTs;
	if (prev && dt > 0 && dt < 60) {
		var dtot = s.cpu.total - prev.cpu.total;
		var didle = s.cpu.idle - prev.cpu.idle;
		if (dtot > 0)
			cpuUsage = Math.max(0, Math.min(100, 100 * (1 - didle / dtot)));

		var pmap = {}, pRx = 0, pTx = 0, sumRx = 0, sumTx = 0;
		(prev.traffic || []).forEach(function(t) { pmap[t.device] = t; pRx += t.rx; pTx += t.tx; });
		(s.traffic || []).forEach(function(t) {
			sumRx += t.rx; sumTx += t.tx;
			var p = pmap[t.device];
			t.rxRate = p ? Math.max(0, (t.rx - p.rx) / dt) : 0;
			t.txRate = p ? Math.max(0, (t.tx - p.tx) / dt) : 0;
		});
		rateRx = Math.max(0, (sumRx - pRx) / dt);
		rateTx = Math.max(0, (sumTx - pTx) / dt);
		rxHistory.push(rateRx); txHistory.push(rateTx);
		if (rxHistory.length > HISTORY) rxHistory.shift();
		if (txHistory.length > HISTORY) txHistory.shift();
	}
	prev = s;
	prevTs = s.ts;
}

function uplinkCounters(s) {
	var up = s.uplink || {}, list = s.traffic || [], i;
	for (i = 0; i < list.length; i++)
		if (list[i].device === up.device) return list[i];
	return null;
}

function paint(s) {
	var up = s.uplink || {}, car = s.carrier || {}, sig = s.signal || {};
	var clients = s.clients || s.leases || [];
	var lv = signalLevel(sig.rsrp || 0);
	var c = uplinkCounters(s);

	dom.pill.className = 'sd-pill' + (up.connected ? '' : ' off');
	dom.pill.textContent = up.connected ? _('Online') : _('Offline');
	dom.host.textContent = _('System Dashboard');
	var bits = [];
	if (car.name) bits.push(car.name);
	if (up.device) bits.push(up.device);
	if (up.ip) bits.push(up.ip);
	bits.push(_('Uptime') + ' ' + humanUptime(s.uptime));
	dom.hostSub.textContent = bits.join(' · ');

	dom.sig.innerHTML =
		'<div class="sd-sigrow">' +
			'<div>' +
				'<div class="sd-big">' + (sig.rsrp || '—') + '<small>dBm</small></div>' +
				'<div class="sd-sub" style="color:' + lv.color + ';font-weight:600;margin-top:2px">' + lv.text + '</div>' +
				bars(lv.bars) +
			'</div>' +
			tiles([
				['RSRQ', (sig.rsrq || '—') + ' dB'],
				['SINR', (sig.sinr || '—') + ' dB'],
				['RSSI', (sig.rssi || '—') + ' dBm'],
				[_('Network mode'), esc(sig.mode || '—')],
				[_('Bandwidth'), sig.bw ? esc(sig.bw) + ' MHz' : '—']
			]) +
		'</div>';

	dom.net.innerHTML =
		'<div class="sd-tiles">' +
			'<div class="sd-tile"><div class="sd-sub">' + _('Operator') + '</div><b>' +
				(car.name ? '<span class="sd-dot" style="background:' + esc(car.color || '#8a8a8a') + '"></span>' + esc(car.name) : '—') + '</b></div>' +
			'<div class="sd-tile"><div class="sd-sub">' + _('Network mode') + '</div><b>' +
				esc((sig.mode || '—') + (sig.duplex ? ' ' + sig.duplex : '')) + '</b></div>' +
			'<div class="sd-tile"><div class="sd-sub">' + _('Data network') + '</div><b>' +
				(up.connected ? 'IPv4' : '—') + '</b></div>' +
		'</div>' +
		tiles([
			[_('Uplink device'), esc(up.device || '—')],
			[_('IP address'), esc(up.ip || '—')],
			[_('Gateway'), esc(up.gateway || '—')],
			[_('Cell ID'), esc(sig.cell_id || '—')],
			['PCI', esc(sig.pci || '—')],
			['EARFCN', esc(sig.earfcn || '—')]
		]);

	dom.tr.innerHTML =
		tiles([
			[_('Download') + ' ' + _('realtime'), humanRate(rateRx)],
			[_('Upload') + ' ' + _('realtime'), humanRate(rateTx)],
			[_('Received'), c ? humanBytes(c.rx) : '—'],
			[_('Sent'), c ? humanBytes(c.tx) : '—'],
			[_('Total'), c ? humanBytes(c.rx + c.tx) : '—']
		]) +
		'<div class="sd-spark" style="margin-top:10px">' +
			spark(rxHistory, '#4a90e2') + spark(txHistory, '#7b61c9') +
		'</div>';

	dom.clientsCount.textContent = '(' + clients.length + ')';
	if (!clients.length) {
		dom.clients.innerHTML = '<div class="sd-empty">' + _('No data') + '</div>';
	} else {
		var srcLabel = { dhcp: 'DHCP', arp: 'ARP' }, html = '<table class="table"><thead><tr><th>' +
			_('Hostname') + '</th><th>' + _('IP address') + '</th><th>' + _('MAC address') +
			'</th><th>' + _('Source') + '</th></tr></thead><tbody>';
		for (var i = 0; i < clients.length; i++)
			html += '<tr><td>' + esc(clients[i].host || clients[i].ip) + '</td><td>' + esc(clients[i].ip) +
				'</td><td>' + esc(clients[i].mac) + '</td><td>' +
				esc(srcLabel[clients[i].source] || clients[i].source || '—') + '</td></tr>';
		dom.clients.innerHTML = html + '</tbody></table>';
	}

	dom.legendRx.textContent = humanRate(rateRx);
	dom.legendTx.textContent = humanRate(rateTx);
	dom.chart.innerHTML = chart(rxHistory, txHistory);

	var mem = s.memory || {};
	var memUsed = mem.total > 0 ? Math.round(100 * (mem.total - (mem.available || mem.free || 0)) / mem.total) : 0;
	var temps = s.thermal || [], maxMillic = -273000;
	for (var t = 0; t < temps.length; t++) maxMillic = Math.max(maxMillic, temps[t].millic);
	var tempC = maxMillic > -273000 ? (maxMillic / 1000).toFixed(1) : '—';
	var fan = s.fan || {};
	var fanText = fan.rpm >= 0 ? fan.rpm + ' RPM' : (fan.pwm >= 0 ? Math.round(100 * fan.pwm / (fan.pwm_max || 255)) + '%' : '—');
	function mini(title, value) {
		return '<div><div class="sd-sub">' + title + '</div><div class="sd-big" style="font-size:20px">' + value + '</div></div>';
	}
	dom.mini.innerHTML =
		mini(_('CPU'), Math.round(cpuUsage) + '%') +
		mini(_('Memory'), memUsed + '%') +
		mini(_('Temperature'), tempC + ' °C') +
		mini(_('Fan'), fanText) +
		mini(_('Connections'), s.conntrack >= 0 ? s.conntrack : '—');

	dom.status.textContent = _('Updated') + ': ' +
		new Date(s.ts * 1000).toLocaleTimeString() + ' · ' + POLL_SECONDS + 's';
}

function refresh() {
	return L.resolveDefault(callSnapshot(), {}).then(function(res) {
		if (!res || !res.ts) {
			dom.status.textContent = _('Data unavailable');
			return;
		}
		compute(res);
		paint(res);
	}, function() {
		dom.status.textContent = _('Data unavailable');
	});
}

return view.extend({
	render: function() {
		dom.pill = E('span', { 'class': 'sd-pill' }, _('Offline'));
		dom.host = E('h3', {}, _('System Dashboard'));
		dom.hostSub = E('div', { 'class': 'sd-sub' }, '');
		dom.status = E('span', { 'class': 'sd-sub' }, _('Collecting data…'));
		dom.sig = E('div');
		dom.net = E('div');
		dom.tr = E('div');
		dom.clients = E('div');
		dom.clientsCount = E('span', { 'class': 'sd-sub' }, '');
		dom.chart = E('div', { 'class': 'sd-chart' });
		dom.legendRx = E('span', {}, '—');
		dom.legendTx = E('span', {}, '—');
		dom.mini = E('div', { 'class': 'sd-mini' });

		/* Argon 会强制隐藏 .cbi-section > legend，标题必须用 h3（且为首个子元素） */
		function section(title, extra, body) {
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ title, extra || '' ]),
				body
			]);
		}

		var root = E('div', { 'class': 'sd-root' }, [
			E('style', { 'type': 'text/css' }, CSS),
			E('div', { 'class': 'sd-hero' }, [ dom.pill, dom.host, dom.status ]),
			dom.hostSub,
			section(_('Signal strength'), '', dom.sig),
			section(_('Uplink & network'), '', dom.net),
			section(_('Traffic'), '', dom.tr),
			section(_('Online devices'), dom.clientsCount, dom.clients),
			section(_('Realtime traffic'),
				E('span', { 'class': 'sd-sub' }, [
					E('span', { 'class': 'sd-dot', 'style': 'background:#4a90e2' }), dom.legendRx, '  ',
					E('span', { 'class': 'sd-dot', 'style': 'background:#7b61c9' }), dom.legendTx
				]),
				dom.chart),
			section(_('System'), '', dom.mini),
			E('div', { 'class': 'sd-foot sd-sub' },
				_('Read-only view. Signal values come from the modem; fan speed is controlled by the kernel thermal framework.'))
		]);

		refresh();
		poll.add(refresh, POLL_SECONDS);
		return root;
	}
});
