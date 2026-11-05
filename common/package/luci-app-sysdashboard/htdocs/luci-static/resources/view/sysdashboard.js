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
 * Read-only system dashboard.
 *
 * All data comes from a single rpcd snapshot (sysdashboard.get); this view
 * computes rates / CPU usage by diffing two consecutive snapshots so the
 * backend stays stateless and never sleeps. No external JS libraries.
 *
 * The card palette uses translucent neutral surfaces + inherited text colour,
 * so it works on both light (Bootstrap) and dark (Argon) LuCI themes.
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
	'.sd-root { max-width: 1400px; }',
	'.sd-head { display:flex; align-items:baseline; justify-content:space-between; flex-wrap:wrap; gap:8px; margin-bottom:12px; }',
	'.sd-head h3 { margin:0; font-size:18px; }',
	'.sd-sub { opacity:.65; font-size:12px; }',
	'.sd-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(165px,1fr)); gap:12px; }',
	'.sd-card { background:rgba(127,127,127,.08); border:1px solid rgba(127,127,127,.18); border-radius:10px; padding:14px; min-width:0; }',
	'.sd-cardtitle { font-size:13px; font-weight:600; margin-bottom:10px; }',
	'.sd-label { opacity:.7; font-size:12px; }',
	'.sd-kpi { font-size:25px; font-weight:600; line-height:1.35; }',
	'.sd-row { display:grid; grid-template-columns:2fr 1fr; gap:12px; margin-top:12px; }',
	'.sd-row2 { grid-template-columns:1fr 1fr; }',
	'@media (max-width:900px) { .sd-row, .sd-row2 { grid-template-columns:1fr; } }',
	'.sd-legend { display:flex; gap:18px; font-size:12px; margin-bottom:6px; flex-wrap:wrap; }',
	'.sd-dot { display:inline-block; width:9px; height:9px; border-radius:50%; margin-right:5px; }',
	'.sd-chart svg { width:100%; height:150px; display:block; }',
	'.sd-gridline { stroke:rgba(127,127,127,.25); stroke-width:1; stroke-dasharray:4 4; }',
	'.sd-gauges { display:flex; flex-wrap:wrap; gap:10px; justify-content:space-around; align-items:center; }',
	'.sd-gauge { position:relative; width:88px; height:88px; }',
	'.sd-gauge svg { display:block; }',
	'.sd-track { fill:none; stroke:rgba(127,127,127,.25); stroke-width:8; }',
	'.sd-arc { fill:none; stroke-width:8; stroke-linecap:round; }',
	'.sd-gauge-label { position:absolute; top:0; left:0; right:0; bottom:0; display:flex; flex-direction:column; align-items:center; justify-content:center; pointer-events:none; }',
	'.sd-gauge-label strong { font-size:13px; }',
	'.sd-gauge-label span { font-size:10px; opacity:.7; }',
	'.sd-table { width:100%; font-size:12px; border-collapse:collapse; }',
	'.sd-table th, .sd-table td { padding:5px 6px; border-bottom:1px solid rgba(127,127,127,.15); text-align:left; white-space:nowrap; }',
	'.sd-table th { opacity:.7; font-weight:600; }',
	'.sd-empty { opacity:.6; font-size:12px; padding:10px 0; }',
	'.sd-foot { margin-top:12px; line-height:1.6; }'
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

function gauge(percent, value, label, color) {
	percent = Math.max(0, Math.min(100, percent || 0));
	var c = 2 * Math.PI * 34;
	var off = c * (1 - percent / 100);
	return '<div class="sd-gauge">' +
		'<svg viewBox="0 0 88 88" width="88" height="88">' +
			'<circle class="sd-track" cx="44" cy="44" r="34"/>' +
			'<circle class="sd-arc" cx="44" cy="44" r="34" transform="rotate(-90 44 44)" ' +
				'style="stroke:' + color + ';stroke-dasharray:' + c.toFixed(1) +
				';stroke-dashoffset:' + off.toFixed(1) + '"/>' +
		'</svg>' +
		'<div class="sd-gauge-label"><strong>' + value + '</strong><span>' + label + '</span></div>' +
	'</div>';
}

function chart(rx, tx) {
	var W = 600, H = 140, P = 6, max = 1, i;
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
		return '<path d="' + area + '" fill="' + color + '" opacity="0.16"/>' +
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

function paintGauges(s) {
	var mem = s.memory || {};
	var memUsed = mem.total > 0
		? 100 * (mem.total - (mem.available || mem.free || 0)) / mem.total : 0;

	var temps = s.thermal || [], maxMillic = -273000, i;
	for (i = 0; i < temps.length; i++) maxMillic = Math.max(maxMillic, temps[i].millic);
	var tempC = maxMillic > -273000 ? maxMillic / 1000 : null;
	var tempColor = (tempC !== null && tempC >= 75) ? '#e05a4f' : '#e2a03f';

	var fan = s.fan || {};
	var fanPct = (fan.pwm >= 0 && fan.pwm_max > 0) ? 100 * fan.pwm / fan.pwm_max : null;
	var fanText = fan.rpm >= 0 ? fan.rpm + ' RPM' :
		(fanPct !== null ? Math.round(fanPct) + '%' : _('N/A'));
	if (fan.rpm < 0 && fan.pwm < 0) fanText = _('N/A');

	dom.gauges.innerHTML =
		gauge(cpuUsage, Math.round(cpuUsage) + '%', _('CPU'), '#4a90e2') +
		gauge(memUsed, Math.round(memUsed) + '%', _('Memory'), '#7b61c9') +
		gauge(tempC === null ? 0 : (tempC - 20) / 70 * 100,
			tempC === null ? '—' : tempC.toFixed(1) + '°C', _('Temperature'), tempColor) +
		gauge(fanPct === null ? 0 : fanPct, fanText, _('Fan'), '#38a89b');

	if (fan.state >= 0 && fan.state_max >= 0)
		dom.fanExtra.textContent = _('Thermal level') + ' ' + fan.state + '/' + fan.state_max +
			(fan.name ? ' (' + fan.name + ')' : '');
	else
		dom.fanExtra.textContent = fan.name ? fan.name : '';
}

function paintTables(s) {
	var traffic = s.traffic || [], leases = s.leases || [], html, i;

	if (!traffic.length) {
		dom.iftable.innerHTML = '<div class="sd-empty">' + _('No data') + '</div>';
	} else {
		html = '<table class="sd-table"><thead><tr><th>' + _('Interface') +
			'</th><th>' + _('Download') + '</th><th>' + _('Upload') + '</th></tr></thead><tbody>';
		for (i = 0; i < traffic.length; i++)
			html += '<tr><td>' + esc(traffic[i].device) + '</td><td>' +
				humanRate(traffic[i].rxRate || 0) + '</td><td>' +
				humanRate(traffic[i].txRate || 0) + '</td></tr>';
		dom.iftable.innerHTML = html + '</tbody></table>';
	}

	if (!leases.length) {
		dom.clients.innerHTML = '<div class="sd-empty">' + _('No data') + '</div>';
	} else {
		html = '<table class="sd-table"><thead><tr><th>' + _('Hostname') +
			'</th><th>' + _('IP address') + '</th><th>' + _('MAC address') + '</th></tr></thead><tbody>';
		for (i = 0; i < leases.length; i++)
			html += '<tr><td>' + esc(leases[i].host) + '</td><td>' + esc(leases[i].ip) +
				'</td><td>' + esc(leases[i].mac) + '</td></tr>';
		dom.clients.innerHTML = html + '</tbody></table>';
	}
}

function paint(s) {
	dom.kpiClients.textContent = (s.leases || []).length;
	dom.kpiConn.textContent = s.conntrack >= 0 ? s.conntrack : '—';
	dom.kpiUptime.textContent = humanUptime(s.uptime);
	dom.kpiLoad.textContent = (s.load || [0, 0, 0]).join(' / ');
	dom.status.textContent = _('Updated') + ': ' +
		new Date(s.ts * 1000).toLocaleTimeString() + ' · ' + POLL_SECONDS + 's';

	dom.legendRx.textContent = humanRate(rateRx);
	dom.legendTx.textContent = humanRate(rateTx);
	dom.chart.innerHTML = chart(rxHistory, txHistory);
	paintGauges(s);
	paintTables(s);
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

function card(label, valueNode, sub) {
	return E('div', { 'class': 'sd-card' }, [
		E('div', { 'class': 'sd-label' }, label),
		valueNode,
		E('div', { 'class': 'sd-sub' }, sub)
	]);
}

return view.extend({
	render: function() {
		dom.kpiClients = E('div', { 'class': 'sd-kpi' }, '—');
		dom.kpiConn = E('div', { 'class': 'sd-kpi' }, '—');
		dom.kpiUptime = E('div', { 'class': 'sd-kpi' }, '—');
		dom.kpiLoad = E('div', { 'class': 'sd-kpi' }, '—');
		dom.status = E('span', { 'class': 'sd-sub' }, _('Collecting data…'));
		dom.chart = E('div', { 'class': 'sd-chart' });
		dom.gauges = E('div', { 'class': 'sd-gauges' });
		dom.fanExtra = E('div', { 'class': 'sd-sub' }, '');
		dom.iftable = E('div');
		dom.clients = E('div');
		dom.legendRx = E('span', {}, '—');
		dom.legendTx = E('span', {}, '—');

		var root = E('div', { 'class': 'cbi-section sd-root' }, [
			E('style', { 'type': 'text/css' }, CSS),
			E('div', { 'class': 'sd-head' }, [
				E('h3', {}, _('System Dashboard')),
				dom.status
			]),
			E('div', { 'class': 'sd-grid' }, [
				card(_('Online clients'), dom.kpiClients, _('DHCP leases')),
				card(_('Connections'), dom.kpiConn, _('Tracked connections')),
				card(_('Uptime'), dom.kpiUptime, _('Since last boot')),
				card(_('Load average'), dom.kpiLoad, '1 / 5 / 15 min')
			]),
			E('div', { 'class': 'sd-row' }, [
				E('div', { 'class': 'sd-card' }, [
					E('div', { 'class': 'sd-cardtitle' }, _('Realtime traffic')),
					E('div', { 'class': 'sd-legend' }, [
						E('span', {}, [
							E('span', { 'class': 'sd-dot', 'style': 'background:#4a90e2' }),
							E('span', {}, _('Download') + ' '),
							dom.legendRx
						]),
						E('span', {}, [
							E('span', { 'class': 'sd-dot', 'style': 'background:#7b61c9' }),
							E('span', {}, _('Upload') + ' '),
							dom.legendTx
						])
					]),
					dom.chart
				]),
				E('div', { 'class': 'sd-card' }, [
					E('div', { 'class': 'sd-cardtitle' }, _('System load')),
					dom.gauges,
					dom.fanExtra
				])
			]),
			E('div', { 'class': 'sd-row sd-row2' }, [
				E('div', { 'class': 'sd-card' }, [
					E('div', { 'class': 'sd-cardtitle' }, _('Interfaces')),
					dom.iftable
				]),
				E('div', { 'class': 'sd-card' }, [
					E('div', { 'class': 'sd-cardtitle' }, _('Online terminals')),
					dom.clients
				])
			]),
			E('div', { 'class': 'sd-foot sd-sub' },
				_('Read-only view. Fan speed is controlled by the kernel thermal framework; this page only displays it.'))
		]);

		refresh();
		poll.add(refresh, POLL_SECONDS);
		return root;
	}
});
