'use strict';
'require baseclass';
'require rpc';
'require view.dashboard.lib.charts as charts';

/*
 * 蜂窝 / 上联 部件 —— 挂到官方 luci-mod-dashboard 上（include 目录会被自动发现）。
 *
 * 为什么这么做：自绘页面很难和 Argon/原生观感一致；直接注册部件则完全复用
 * 官方的 KPI 卡片、卡片容器与标签页样式，天然一体。
 *
 * 数据来自本包 rpcd 的 sysdashboard.get（只读快照）：
 *   signal  —— QModem cell_info 的 RSRP/RSRQ/SINR/制式/带宽
 *   uplinks —— 多 WAN 候选（wwan0 / wan / usb0 ...），支持标签页切换
 *   clients —— DHCP 租约 + ARP 邻居合并（静态 IP、无限租期设备也能看到）
 */

var callSnap = rpc.declare({
	object: 'sysdashboard',
	method: 'get'
});

var DEV_LABEL = {
	wwan0: _('5G cellular'),
	wan: _('WAN port'),
	usb0: _('USB tethering'),
	wanusb: _('USB WAN')
};

var selected = null;   /* 跨轮询保留当前选中的 WAN */

function fmtBytes(n) {
	n = Math.max(0, n || 0);
	var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (i === 0 ? n.toFixed(0) : n.toFixed(1)) + ' ' + u[i];
}

function kvTable(rows) {
	var body = E('tbody', {});
	rows.forEach(function(r) {
		body.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'data-title': _('Item') }, [r[0]]),
			E('td', { 'class': 'td', 'data-title': _('Value') }, [r[1]])
		]));
	});
	return E('table', { 'class': 'table' }, [ body ]);
}

return baseclass.extend({
	title: _('Cellular'),
	widgets: [
		{ id: 'cell-signal', slot: 'cards', title: _('Signal'), order: 12 },
		{ id: 'cell-uplink', slot: 'cards', title: _('Uplink'), order: 13 },
		{ id: 'cell-uplink-tab', slot: 'tabs', title: _('Uplink'), order: 15 },
		{ id: 'cell-clients', slot: 'tabs', title: _('Online devices'), order: 16 }
	],

	load: function() {
		return L.resolveDefault(callSnap(), null);
	},

	/* 上联标签页：每个 WAN 一个标签，点选切换 */
	uplinkPane: function(ups, up) {
		var body = E('div', {});
		var menu = E('ul', { 'class': 'cbi-tabmenu' });

		function activeDevice() {
			if (selected && ups.some(function(u) { return u.device === selected; }))
				return selected;
			if (up.device && ups.some(function(u) { return u.device === up.device; }))
				return up.device;
			return ups.length ? ups[0].device : null;
		}

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
				[_('Uplink device'), cur.device || '—'],
				[_('Status'), cur.connected ? _('Connected') : _('Not connected')],
				[_('IP address'), cur.ip || '—'],
				[_('Gateway'), cur.gateway || '—'],
				[_('Received'), fmtBytes(cur.rx)],
				[_('Sent'), fmtBytes(cur.tx)]
			]));
		}

		if (!ups.length) {
			body.appendChild(charts.empty(_('No data')));
			return body;
		}

		ups.forEach(function(u) {
			var li = E('li', { 'data-tab': u.device }, [
				E('a', {
					'href': '#',
					'click': function(ev) { ev.preventDefault(); paint(u.device); }
				}, [ DEV_LABEL[u.device] || u.device ])
			]);
			menu.appendChild(li);
		});

		paint(activeDevice());
		return E('div', {}, [ menu, body ]);
	},

	render: function(snap) {
		if (!snap || !snap.ts)
			return null;

		var sig = snap.signal || {}, up = snap.uplink || {}, car = snap.carrier || {};
		var ups = snap.uplinks || [], clients = snap.clients || snap.leases || [];
		var live = ups.filter(function(u) { return u.connected; });
		if (live.length) ups = live;

		/*
		 * 只返回“有数据”的卡片：官方面板按 id 从 layout 里取节点，缺 id 即不渲染。
		 * 这样未连接/没模组时，对应的状态卡会自动消失，而不是挂一张“未连接”的空卡。
		 */
		var cards = [];

		if (sig.rsrp)
			cards.push({
				id: 'cell-signal',
				node: charts.kpi({
					icon: 'wireless',
					title: _('Signal'),
					value: sig.rsrp + ' dBm',
					sub: [ car.name || '', sig.mode || '' ],
					stacked: true
				})
			});

		if (up.connected)
			cards.push({
				id: 'cell-uplink',
				node: charts.kpi({
					icon: 'internet',
					title: _('Uplink'),
					value: up.device || '—',
					sub: [ up.ip || '', up.gateway ? _('Gateway') + ' ' + up.gateway : '' ],
					stacked: true
				})
			});

		var tabs = [
			{
				id: 'cell-uplink-tab',
				title: _('Uplink'),
				content: this.uplinkPane(ups, up)
			},
			{
				id: 'cell-clients',
				title: _('Online devices'),
				count: clients.length,
				content: (function() {
					if (!clients.length)
						return charts.empty(_('No data'));
					var srcLabel = { dhcp: 'DHCP', arp: 'ARP' };
					var tbody = E('tbody', {});
					clients.forEach(function(c) {
						tbody.appendChild(E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td', 'data-title': _('Hostname') }, [c.host || c.ip]),
							E('td', { 'class': 'td', 'data-title': _('IP address') }, [c.ip]),
							E('td', { 'class': 'td', 'data-title': _('MAC address') }, [c.mac]),
							E('td', { 'class': 'td', 'data-title': _('Source') }, [srcLabel[c.source] || c.source || '—'])
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
				})()
			}
		];

		return { cards: cards, tabs: tabs };
	}
});
