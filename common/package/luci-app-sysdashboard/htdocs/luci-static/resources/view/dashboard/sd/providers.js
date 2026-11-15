'use strict';
'require baseclass';
'require view.dashboard.lib.charts as charts';
'require view.dashboard.sd.util as util';

/*
 * 我们自己实现的部件内容（所有判定都走 snap / caps，不碰 netifd）：
 *   cards.internet       运营商 + 上联 IP/网关（官方用 netifd，5G 恒判「未连接」）
 *   cards.cell-signal    信号强度（RSRP + 等级 + RSRQ/SINR）
 *   cards.cellular       网络状态（运营商 / 制式 / 频段 / 带宽）
 *   cards.traffic-usage  流量统计（本次累计收发）
 *   charts.wan           上联设备真实计数（官方只认 netifd 的 WAN）
 *   cards.dhcp           在线设备数（租约 + ARP 合并）
 *   tabs.internet        上联详情：WAN 切换 + 信号 / 网络 / 流量三张明细表
 *   tabs.dhcp            在线设备表（带来源列）
 *
 * 系统类部件不在这里：内容仍由官方 include 提供，我们只负责统一注册与可用性。
 */

var DEV_LABEL = {
	wwan0: _('5G cellular'),
	wan: _('WAN port'),
	usb0: _('USB tethering'),
	wanusb: _('USB WAN')
};

var HIST = 40, rxHist = [], txHist = [];
var prev = null, prevTs = 0, selectedDev = null;
var peakRx = 0, peakTx = 0;

/* RSRP 分档（与信号卡片一致） */
function signalLevel(rsrp) {
	if (!rsrp) return { bars: 0, text: _('No signal') };
	if (rsrp >= -85) return { bars: 5, text: _('Excellent') };
	if (rsrp >= -95) return { bars: 4, text: _('Good') };
	if (rsrp >= -105) return { bars: 3, text: _('Fair') };
	if (rsrp >= -115) return { bars: 2, text: _('Weak') };
	return { bars: 1, text: _('Very weak') };
}

function fmtDuration(sec) {
	sec = Math.max(0, Math.floor(sec || 0));
	var d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600),
		m = Math.floor(sec % 3600 / 60), s = sec % 60;
	function p(n) { return (n < 10 ? '0' : '') + n; }
	return (d ? d + 'd ' : '') + p(h) + ':' + p(m) + ':' + p(s);
}

return baseclass.extend({
	/* 每次轮询调用一次：用两次快照差分出速率，并累积曲线历史与峰值 */
	track: function(snap) {
		var dt = snap.ts - prevTs, i;

		if (prev && dt > 0 && dt < 60) {
			var pmap = {};
			(prev.traffic || []).forEach(function(t) { pmap[t.device] = t; });
			(snap.traffic || []).forEach(function(t) {
				var p = pmap[t.device];
				t.rxRate = p ? Math.max(0, (t.rx - p.rx) / dt) : 0;
				t.txRate = p ? Math.max(0, (t.tx - p.tx) / dt) : 0;
			});

			var cur = this.uplinkTraffic(snap);
			var rx = cur ? cur.rxRate : 0, tx = cur ? cur.txRate : 0;
			rxHist.push(rx);
			txHist.push(tx);
			if (rxHist.length > HIST) rxHist.shift();
			if (txHist.length > HIST) txHist.shift();
			peakRx = Math.max(peakRx, rx);
			peakTx = Math.max(peakTx, tx);
		}

		prev = snap;
		prevTs = snap.ts;
	},

	uplinkTraffic: function(snap) {
		var up = snap.uplink || {};
		var list = snap.traffic || [];
		for (var i = 0; i < list.length; i++)
			if (list[i].device === up.device) return list[i];
		return null;
	},

	card: function(id, snap, caps) {
		var up = snap.uplink || {}, car = snap.carrier || {};
		var sig = snap.signal || {}, cell = snap.cell || {}, usage = snap.usage || {};

		if (id === 'internet')
			return charts.kpi({
				icon: 'internet',
				title: _('Internet'),
				value: car.name || up.device || '—',
				sub: [ up.ip || '', up.gateway ? _('Gateway') + ' ' + up.gateway : '' ],
				stacked: true
			});

		/* 信号强度：大号 RSRP + 等级 + 主要质量指标 */
		if (id === 'cell-signal') {
			var lv = signalLevel(sig.rsrp);
			return charts.kpi({
				icon: 'wireless',
				title: _('Signal strength'),
				value: (sig.rsrp || '—') + ' dBm',
				sub: [
					lv.text,
					[ 'RSRQ ' + (sig.rsrq || '—') + ' dB', 'SINR ' + (sig.sinr || '—') + ' dB' ].join(' · ')
				],
				stacked: true
			});
		}

		/* 网络状态：运营商 + 制式 + 频段/带宽（有频率就带上） */
		if (id === 'cellular') {
			var net = [];
			if (sig.mode || sig.duplex)
				net.push([ sig.mode, sig.duplex ].filter(Boolean).join(' '));
			var radio = [];
			if (cell.band_name) radio.push(cell.band_name);
			if (cell.freq_mhz) radio.push(cell.freq_mhz + ' MHz');
			if (cell.dl_bw) radio.push(cell.dl_bw + ' MHz');
			return charts.kpi({
				icon: 'router',
				title: _('Network status'),
				value: car.name || '—',
				sub: [ net.join(' '), radio.join(' · ') ],
				stacked: true
			});
		}

		/* 流量统计：本次累计（QModem 自带统计，跨重启持久） */
		if (id === 'traffic-usage') {
			var total = (usage.rx || 0) + (usage.tx || 0);
			return charts.kpi({
				icon: 'devices',
				title: _('Data usage'),
				value: util.fmtBytes(total),
				sub: [ '↓ ' + util.fmtBytes(usage.rx) + ' · ↑ ' + util.fmtBytes(usage.tx) ],
				stacked: true
			});
		}

		if (id === 'dhcp')
			return charts.kpi({
				icon: 'devices',
				title: _('DHCP Devices'),
				value: String(caps.count.clients),
				sub: [ _('DHCP leases') + ' + ' + _('ARP') ],
				stacked: true
			});

		return null;
	},

	chart: function(id, snap) {
		if (id !== 'wan')
			return null;

		var up = snap.uplink || {}, cur = this.uplinkTraffic(snap);

		return charts.card({
			title: _('WAN traffic'),
			desc: (DEV_LABEL[up.device] || up.device || '') + ' · ' +
				util.fmtRate(cur ? cur.rxRate || 0 : 0) + ' ↓ / ' +
				util.fmtRate(cur ? cur.txRate || 0 : 0) + ' ↑',
			body: [
				util.svgSeries(rxHist, '#4a90e2', 600, 120, HIST),
				util.svgSeries(txHist, '#7b61c9', 600, 120, HIST)
			]
		});
	},

	tab: function(id, snap, caps) {
		if (id === 'internet')
			return { content: this.detail(snap, caps) };

		if (id === 'dhcp')
			return { content: this.clientTable(snap), count: caps.count.clients };

		return null;
	},

	/* 上联详情：WAN 切换 + 信号 / 网络 / 流量 三张明细表 */
	detail: function(snap, caps) {
		var sig = snap.signal || {}, cell = snap.cell || {}, usage = snap.usage || {};
		var car = snap.carrier || {}, up = snap.uplink || {};
		var used = (usage.rx || 0) + (usage.tx || 0);
		var dur = usage.since ? (Date.now() / 1000 - usage.since) : 0;

		var parts = [ this.uplinkPane(snap) ];

		parts.push(E('h3', {}, [ _('Signal strength') ]));
		parts.push(util.kvTable([
			[ 'RSRP', (sig.rsrp || '—') + ' dBm' ],
			[ 'RSRQ', (sig.rsrq || '—') + ' dB' ],
			[ 'SINR', (sig.sinr || '—') + ' dB' ],
			[ 'RSSI', (sig.rssi || '—') + ' dBm' ],
			[ 'CQI', sig.cqi || '—' ],
			[ 'Srxlev', sig.srxlev || '—' ],
			[ _('Bandwidth'), sig.bw ? sig.bw + ' MHz' : '—' ]
		]));

		parts.push(E('h3', {}, [ _('Network status') ]));
		parts.push(util.kvTable([
			[ _('Operator'), (car.name || '—') + (car.mcc ? ' · ' + car.mcc + '/' + car.mnc : '') ],
			[ _('Network mode'), [ sig.mode, sig.duplex ].filter(Boolean).join(' ') || '—' ],
			[ _('Band'), (cell.band_name || cell.band || '—') +
				(cell.freq_mhz ? ' · ' + cell.freq_mhz + ' MHz' : '') +
				(cell.dl_bw ? ' · ' + cell.dl_bw + ' MHz' : '') ],
			[ _('Channel'), (cell.channel || '—') + (cell.channel_type ? ' (' + cell.channel_type + ')' : '') ],
			[ _('Carrier aggregation'), cell.role ? (cell.role === 'pcc' ? _('Single carrier (PCC)') : cell.role.toUpperCase()) : '—' ],
			[ _('Cell ID'), (sig.cell_id || '—') + (sig.tac ? ' · TAC ' + sig.tac : '') ],
			[ 'PCI', sig.pci || '—' ],
			[ _('IP address'), up.ip || '—' ],
			[ 'IPv6', snap.ipv6 || _('Not assigned') ]
		]));

		parts.push(E('h3', {}, [ _('Traffic') ]));
		parts.push(util.kvTable([
			[ _('Received'), util.fmtBytes(usage.rx) ],
			[ _('Sent'), util.fmtBytes(usage.tx) ],
			[ _('Total'), util.fmtBytes(used) ],
			[ _('Connected for'), dur ? fmtDuration(dur) : '—' ],
			[ _('Peak down / up'), util.fmtRate(peakRx) + ' / ' + util.fmtRate(peakTx) ],
			[ _('Monthly reset'), usage.reset_enabled
				? _('Day %d of each month').format(usage.reset_day || 1)
				: _('Disabled') ]
		]));

		return E('div', {}, parts);
	},

	/* 上联详情：每个在线 WAN 一个子标签，点选切换（选中项跨刷新保持） */
	uplinkPane: function(snap) {
		var ups = (snap.uplinks || []).filter(function(u) { return u.connected; });
		var body = E('div', {});
		var menu = E('ul', { 'class': 'cbi-tabmenu' });

		function paint(dev) {
			selectedDev = dev;
			Array.prototype.forEach.call(menu.children, function(li) {
				if (li.getAttribute('data-tab') === dev)
					li.setAttribute('class', 'cbi-tab');
				else
					li.removeAttribute('class');
			});
			var cur = ups.filter(function(u) { return u.device === dev; })[0] || {};
			L.dom.content(body, util.kvTable([
				[ _('Uplink device'), cur.device || '—' ],
				[ _('Status'), _('Connected') ],
				[ _('IP address'), cur.ip || '—' ],
				[ _('Gateway'), cur.gateway || '—' ],
				[ _('Received'), util.fmtBytes(cur.rx) ],
				[ _('Sent'), util.fmtBytes(cur.tx) ]
			]));
		}

		if (!ups.length)
			return charts.empty(_('No data'));

		ups.forEach(function(u) {
			menu.appendChild(E('li', { 'data-tab': u.device }, [
				E('a', { 'href': '#', 'click': function(ev) { ev.preventDefault(); paint(u.device); } },
					[ DEV_LABEL[u.device] || u.device ])
			]));
		});

		var init = (selectedDev && ups.some(function(u) { return u.device === selectedDev; }))
			? selectedDev : ups[0].device;
		paint(init);

		return E('div', {}, [ menu, body ]);
	},

	/* 在线设备表：租约 + ARP 合并结果，标注来源 */
	clientTable: function(snap) {
		var clients = snap.clients || snap.leases || [];
		if (!clients.length)
			return charts.empty(_('No data'));

		var srcLabel = { dhcp: 'DHCP', arp: 'ARP' };
		var tbody = E('tbody', {});

		clients.forEach(function(c) {
			tbody.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'data-title': _('Hostname') }, [ c.host || c.ip ]),
				E('td', { 'class': 'td', 'data-title': _('IP address') }, [ c.ip ]),
				E('td', { 'class': 'td', 'data-title': _('MAC address') }, [ c.mac ]),
				E('td', { 'class': 'td', 'data-title': _('Source') }, [ srcLabel[c.source] || c.source || '—' ])
			]));
		});

		return E('table', { 'class': 'table' }, [
			E('thead', {}, [ E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, [ _('Hostname') ]),
				E('th', { 'class': 'th' }, [ _('IP address') ]),
				E('th', { 'class': 'th' }, [ _('MAC address') ]),
				E('th', { 'class': 'th' }, [ _('Source') ])
			]) ]),
			tbody
		]);
	}
});
