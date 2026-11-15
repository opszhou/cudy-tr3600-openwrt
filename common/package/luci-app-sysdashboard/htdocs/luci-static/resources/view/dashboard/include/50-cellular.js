'use strict';
'require baseclass';
'require rpc';
'require view.dashboard.lib.charts as charts';

/*
 * 接管官方 luci-mod-dashboard 的几个部件（同 id 覆盖，文件名靠后先加载 → 后注册者胜出）：
 *   cards.internet  ← 官方按 netifd 判定，5G 的 wwan0 不在 netifd 里，永远「未连接」
 *   charts.wan      ← 官方同样只认 netifd 的 WAN，wwan0 流量恒为空
 *   tabs.dhcp       ← 官方只读 DHCP 租约；无限租期/静态 IP 设备看不到
 *   tabs.internet   ← 换成带 WAN 切换标签的详情
 * 另加 cards.cell-signal（信号）。
 *
 * 数据全部来自本包 rpcd 的 sysdashboard.get（只读快照，无状态、不落盘）。
 */

var callSnap = rpc.declare({ object: 'sysdashboard', method: 'get' });

var DEV_LABEL = {
	wwan0: _('5G cellular'),
	wan: _('WAN port'),
	usb0: _('USB tethering'),
	wanusb: _('USB WAN')
};

var prev = null, prevTs = 0, selected = null;
var HIST = 40, rxHist = [], txHist = [];

function fmtBytes(n) {
	n = Math.max(0, n || 0);
	var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (i === 0 ? n.toFixed(0) : n.toFixed(1)) + ' ' + u[i];
}
function fmtRate(n) { return fmtBytes(n) + '/s'; }

function kvTable(rows) {
	var body = E('tbody', {});
	rows.forEach(function(r) {
		body.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '40%' }, [ r[0] ]),
			E('td', { 'class': 'td left' }, [ r[1] ])
		]));
	});
	return E('table', { 'class': 'table' }, [ body ]);
}

function svgSeries(values, color, w, h) {
	var ns = 'http://www.w3.org/2000/svg';
	var max = 1, i, pts = [];
	for (i = 0; i < values.length; i++) max = Math.max(max, values[i]);
	for (i = 0; i < values.length; i++) {
		var x = 3 + (w - 6) * i / (HIST - 1);
		var y = h - 3 - (h - 6) * values[i] / max;
		pts.push((i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1));
	}
	var svg = document.createElementNS(ns, 'svg');
	svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
	svg.setAttribute('width', '100%');
	svg.setAttribute('height', h);
	svg.setAttribute('preserveAspectRatio', 'none');
	var path = document.createElementNS(ns, 'path');
	path.setAttribute('d', pts.join(' ') || 'M0 0');
	path.setAttribute('fill', 'none');
	path.setAttribute('stroke', color);
	path.setAttribute('stroke-width', '2');
	svg.appendChild(path);
	return svg;
}

/* DHCP/ARP 合并后的设备表 */
function dhcpTable(clients) {
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

/*
 * 标签显隐：用 body 状态类 + CSS，而不是删 DOM 节点。
 * 这样官方的 tab 机制（ui.tabs.initTabGroup / updateTabs）不受影响，
 * 数据恢复时只要去掉状态类，标签立刻回来。
 */
var TAB_CSS = [
	'body.sd-no-internet-tab [data-tab="internet"] { display: none !important; }',
	'body.sd-no-dhcp-tab [data-tab="dhcp"] { display: none !important; }'
].join('\n');

var cssReady = false;

function setTabState(showUplink, showDhcp) {
	if (typeof document === 'undefined' || !document.body)
		return;

	if (!cssReady) {
		var head = document.head || document.querySelector('head');
		if (head)
			head.appendChild(E('style', { 'type': 'text/css' }, TAB_CSS));
		cssReady = true;
	}

	document.body.classList.toggle('sd-no-internet-tab', !showUplink);
	document.body.classList.toggle('sd-no-dhcp-tab', !showDhcp);

	/* 选中项被隐藏时切到第一个可见标签，避免内容区空白 */
	if (typeof requestAnimationFrame !== 'function')
		return;

	requestAnimationFrame(function() {
		var group = document.querySelector('.cbi-map-tabbed');
		if (!group)
			return;

		var panes = Array.prototype.filter.call(group.children, function(el) {
			return el.dataset && el.dataset.tab;
		});
		var active = panes.filter(function(el) { return el.dataset.tabActive === 'true'; })[0];

		if (!active || getComputedStyle(active).display !== 'none')
			return;

		var next = panes.filter(function(el) { return getComputedStyle(el).display !== 'none'; })[0];
		if (!next)
			return;

		var menu = group.querySelector('.cbi-tabmenu');
		var link = menu && menu.querySelector('li[data-tab="' + next.dataset.tab + '"] > a');
		if (link)
			link.click();
	});
}

return baseclass.extend({
	title: _('Cellular'),
	widgets: [
		{ id: 'internet', slot: 'cards', title: _('Internet'), order: 10 },
		{ id: 'cell-signal', slot: 'cards', title: _('Signal'), order: 12 },
		{ id: 'wan', slot: 'charts', title: _('WAN traffic'), order: 10 },
		{ id: 'internet', slot: 'tabs', title: _('Internet'), order: 10 },
		{ id: 'dhcp', slot: 'tabs', title: _('DHCP Devices'), order: 40 }
	],

	load: function() {
		return L.resolveDefault(callSnap(), null);
	},

	/* 上联详情：每个在线 WAN 一个标签，点选切换 */
	uplinkPane: function(ups) {
		var body = E('div', {});
		var menu = E('ul', { 'class': 'cbi-tabmenu' });

		function paint(dev) {
			selected = dev;
			Array.prototype.forEach.call(menu.children, function(li) {
				if (li.getAttribute('data-tab') === dev)
					li.setAttribute('class', 'cbi-tab');
				else
					li.removeAttribute('class');
			});
			var cur = ups.filter(function(u) { return u.device === dev; })[0] || {};
			L.dom.content(body, kvTable([
				[ _('Uplink device'), cur.device || '—' ],
				[ _('Status'), cur.connected ? _('Connected') : _('Not connected') ],
				[ _('IP address'), cur.ip || '—' ],
				[ _('Gateway'), cur.gateway || '—' ],
				[ _('Received'), fmtBytes(cur.rx) ],
				[ _('Sent'), fmtBytes(cur.tx) ]
			]));
		}

		if (!ups.length) {
			body.appendChild(charts.empty(_('No data')));
			return body;
		}

		ups.forEach(function(u) {
			menu.appendChild(E('li', { 'data-tab': u.device }, [
				E('a', { 'href': '#', 'click': function(ev) { ev.preventDefault(); paint(u.device); } },
					[ DEV_LABEL[u.device] || u.device ])
			]));
		});

		var init = (selected && ups.some(function(u) { return u.device === selected; }))
			? selected : (ups[0] && ups[0].device);
		if (init) paint(init);
		return E('div', {}, [ menu, body ]);
	},

	render: function(snap) {
		if (!snap || !snap.ts)
			return null;

		var sig = snap.signal || {}, up = snap.uplink || {}, car = snap.carrier || {};
		var ups = snap.uplinks || [], clients = snap.clients || snap.leases || [];
		var live = ups.filter(function(u) { return u.connected; });
		if (live.length) ups = live;

		/* 速率：两次快照差分，按当前上联设备取计数 */
		var dt = snap.ts - prevTs, i;
		if (prev && dt > 0 && dt < 60) {
			var pmap = {};
			(prev.traffic || []).forEach(function(t) { pmap[t.device] = t; });
			(snap.traffic || []).forEach(function(t) {
				var p = pmap[t.device];
				t.rxRate = p ? Math.max(0, (t.rx - p.rx) / dt) : 0;
				t.txRate = p ? Math.max(0, (t.tx - p.tx) / dt) : 0;
			});
			var curDev = null;
			for (i = 0; i < (snap.traffic || []).length; i++)
				if (snap.traffic[i].device === up.device) curDev = snap.traffic[i];
			rxHist.push(curDev ? curDev.rxRate : 0);
			txHist.push(curDev ? curDev.txRate : 0);
			if (rxHist.length > HIST) rxHist.shift();
			if (txHist.length > HIST) txHist.shift();
		}
		prev = snap;
		prevTs = snap.ts;

		var cur = null;
		for (i = 0; i < (snap.traffic || []).length; i++)
			if (snap.traffic[i].device === up.device) cur = snap.traffic[i];

		/*
		 * 显隐规则：我们接管的 id 一律「始终注册」，无数据时把 node 置 null。
		 * 原因：官方 collectSections 里 found[slot][id] 是后注册覆盖先注册——若干脆
		 * 不返回该 id，10_router / 20_lan 里的同 id 官方部件就会回填，于是又冒出一张
		 * 「未连接」空卡（上一版正是栽在这里）。置 null 会被布局映射后的
		 * .filter(item => item != null) 丢掉，既不显示也不会回填官方版本。
		 */
		var cards = [
			{
				id: 'internet',
				node: up.connected ? charts.kpi({
					icon: 'internet',
					title: _('Internet'),
					value: car.name || up.device || '—',
					sub: [ up.ip || '', up.gateway ? _('Gateway') + ' ' + up.gateway : '' ],
					stacked: true
				}) : null
			},
			{
				id: 'cell-signal',
				node: sig.rsrp ? charts.kpi({
					icon: 'wireless',
					title: _('Signal'),
					value: sig.rsrp + ' dBm',
					sub: [ sig.mode || '', (sig.sinr ? 'SINR ' + sig.sinr + ' dB' : '') ],
					stacked: true
				}) : null
			}
		];

		var chartNodes = [
			{
				id: 'wan',
				node: up.connected ? charts.card({
					title: _('WAN traffic'),
					desc: (DEV_LABEL[up.device] || up.device || '') + ' · ' +
						fmtRate(cur ? cur.rxRate || 0 : 0) + ' ↓ / ' +
						fmtRate(cur ? cur.txRate || 0 : 0) + ' ↑',
					body: [
						svgSeries(rxHist, '#4a90e2', 600, 120),
						svgSeries(txHist, '#7b61c9', 600, 120)
					]
				}) : null
			}
		];

		/*
		 * 标签：官方对 tabs 不做 null 过滤（item 会被包成对象，content 为 null 也照样建
		 * 空面板），所以两个 id 都注册，再用 body 状态类 + CSS 把没数据的标签连同菜单项
		 * 一起隐藏。官方 updateTabs 在数量不变时只更新标题/内容，故状态类每轮都稳定生效；
		 * 数据恢复后下一轮轮询（默认 5s）标签会自动出现。
		 */
		var showUplink = !!(up.connected && ups.length);
		var showDhcp = clients.length > 0;

		var tabs = [
			{
				id: 'internet',
				title: _('Internet'),
				content: showUplink ? this.uplinkPane(ups) : charts.empty('')
			},
			{
				id: 'dhcp',
				title: _('DHCP Devices'),
				count: showDhcp ? clients.length : null,
				content: showDhcp ? dhcpTable(clients) : charts.empty('')
			}
		];

		setTabState(showUplink, showDhcp);

		return { cards: cards, charts: chartNodes, tabs: tabs };
	}
});
