#!/usr/bin/env bash
# 沙箱测试：部件目录 / 能力模型 / 注册中心
#
# 做法：在 Node 里模拟 LuCI 的 'require xxx as y' 语法（这些在普通 JS 里只是
# 字符串表达式），按模块名解析到 sd/*.js 或假的官方 include，然后跑真实代码。
#
# 覆盖：
#   1) catalog 声明完整性（17 个部件、标题带自动隐藏说明、hidden 标记保留）
#   2) 官方 include 被降级为纯内容提供者（widgets 清空、available 返回 false）
#   3) 四种网络状态下的卡片/图表/标签显隐
#   4) 条件恢复后全部回来
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODROOT="$ROOT/common/package/luci-app-sysdashboard/htdocs/luci-static/resources"

[ -d "$MODROOT/view/dashboard/sd" ] || { echo "错误: 找不到 sd 模块目录" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "错误: 缺少 node" >&2; exit 1; }

node - "$MODROOT" <<'EOF'
const fs = require('fs');
const path = require('path');
const MODROOT = process.argv[2];

/* ---------------- LuCI 运行时 mock ---------------- */
globalThis._ = s => s;

/* LuCI 给 String 挂了 format()，这里补上最小实现（只用到 %s / %d） */
String.prototype.format = function() {
	const args = arguments;
	let i = 0;
	return String(this).replace(/%[sd]/g, () => String(args[i++]));
};

function node(tag, attrs, kids) {
	const n = {
		tag, attrs: attrs || {}, children: [], style: {},
		appendChild(c) { this.children.push(c); return c; },
		insertBefore(c) { this.children.unshift(c); return c; },
		setAttribute(k, v) { this.attrs[k] = v; },
		getAttribute(k) { return this.attrs[k]; },
		removeAttribute(k) { delete this.attrs[k]; },
		setProperty() {},
		querySelector() { return null; }
	};
	Array.prototype.forEach.call(kids || [], c => n.children.push(c));
	return n;
}
globalThis.E = node;

const BODY_CLASSES = {};
globalThis.document = {
	head: node('head'),
	body: {
		classList: {
			toggle(name, on) { if (on) BODY_CLASSES[name] = true; else delete BODY_CLASSES[name]; }
		}
	},
	querySelector: () => null,
	querySelectorAll: () => [],
	createElementNS: () => node('svg'),
	createElement: () => node('div')
};

globalThis.rpc = { declare: () => (async () => null) };
globalThis.baseclass = {
	extend: function(o) {
		function C() {}
		Object.assign(C.prototype, o);
		return C;
	}
};
globalThis.L = {
	resolveDefault: (p, d) => Promise.resolve(d),
	dom: { content() {} },
	resource: p => p
};
globalThis.charts = {
	kpi: o => ({ kind: 'kpi', title: o.title }),
	card: o => ({ kind: 'card', title: o.title }),
	empty: () => ({ kind: 'empty' }),
	badge: () => null,
	legend: () => null,
	lines: () => null
};

/* ---------------- 假的官方 include ---------------- */
function fakeInclude(items) {
	return {
		widgets: [ { id: 'stub', slot: 'cards' } ],
		load: () => Promise.resolve({ stub: true }),
		render: () => items
	};
}

const OFFICIAL = {
	'view.dashboard.include.10_router': fakeInclude({
		cards: [ { id: 'internet', node: () => 'OFFICIAL-INTERNET' }, { id: 'uptime', node: () => 'UPTIME' } ],
		tabs: [ { id: 'internet', title: 'Internet', content: () => 'OFFICIAL-INTERNET-TAB' },
		        { id: 'system', title: 'System', content: () => 'SYSTEM-TAB' } ]
	}),
	'view.dashboard.include.12_resources': fakeInclude({
		cards: [ { id: 'cpu', node: 'CPU' }, { id: 'memory', node: 'MEM' }, { id: 'load', node: 'LOAD' } ],
		charts: [ { id: 'system', node: 'SYSTEM-CHART' } ],
		tabs: [ { id: 'resources', title: 'Resources', content: 'RESOURCES-TAB' } ]
	}),
	'view.dashboard.include.15_traffic': fakeInclude({
		charts: [ { id: 'wan', node: 'OFFICIAL-WAN' } ]
	}),
	'view.dashboard.include.20_lan': fakeInclude({
		cards: [ { id: 'dhcp', node: 'OFFICIAL-DHCP' } ],
		tabs: [ { id: 'dhcp', title: 'DHCP Devices', content: 'OFFICIAL-DHCP-TAB' } ]
	}),
	'view.dashboard.include.30_wifi': fakeInclude({
		cards: [ { id: 'wifi', node: 'WIFI-CARD' } ],
		charts: [ { id: 'distribution', node: 'D' }, { id: 'signal', node: 'S' }, { id: 'traffic', node: 'T' } ],
		tabs: [ { id: 'wifi', title: 'Wireless', content: 'WIFI-TAB' } ]
	})
};

/* ---------------- 模块加载器（模拟 LuCI require） ---------------- */
const cache = {};
const RAW = {};

function resolve(name) {
	if (OFFICIAL[name]) return { kind: 'official', name: name };
	if (name === 'view.dashboard.lib.charts') return { kind: 'charts' };
	if (name === 'view.dashboard.include.50-cellular')
		return { kind: 'file', file: path.join(MODROOT, 'view/dashboard/include/50-cellular.js') };
	const m = name.match(/^view\.dashboard\.sd\.([\w-]+)$/);
	if (m) return { kind: 'file', file: path.join(MODROOT, 'view/dashboard/sd', m[1] + '.js') };
	return { kind: 'unknown', name: name };
}

function req(name) {
	const r = resolve(name);
	if (r.kind === 'official') return OFFICIAL[name];
	if (r.kind === 'charts') return globalThis.charts;
	if (r.kind === 'file') return loadFile(r.file);
	throw new Error('未 mock 的模块: ' + name);
}

function loadFile(file) {
	if (cache[file]) return cache[file];

	const src = fs.readFileSync(file, 'utf8');
	const re = /^\s*'require\s+([A-Za-z0-9_.\-]+)(?:\s+as\s+(\w+))?'/gm;
	const prelude = [];
	const seen = new Set();
	let m;
	while ((m = re.exec(src))) {
		if (!m[2] || seen.has(m[2])) continue;
		seen.add(m[2]);
		prelude.push('var ' + m[2] + ' = __req(' + JSON.stringify(m[1]) + ');');
	}

	const fn = new Function('__req', prelude.join('\n') + '\n' + src);
	const raw = fn(req);
	RAW[file] = raw;
	const mod = (typeof raw === 'function') ? new raw() : raw;
	cache[file] = mod;
	return mod;
}

/* ---------------- 断言工具 ---------------- */
let pass = 0, fail = 0;
function check(name, got, want) {
	const g = JSON.stringify(got), w = JSON.stringify(want);
	if (g === w) { pass++; console.log('  OK   ' + name); }
	else { fail++; console.log('  FAIL ' + name + '\n         期望 ' + w + '\n         实际 ' + g); }
}

function snapCaps(o) {
	return {
		wan: { ok: !!o.wan },
		wifi: { ok: !!o.wifi },
		wifi_clients: { ok: !!(o.wifi && o.wifiClients), count: o.wifiClients ? 2 : 0 },
		clients: { ok: !!o.clients, count: o.clients ? 3 : 0 },
		modem: { ok: !!o.modem },
		signal: { ok: !!o.signal }
	};
}

function snap(o) {
	return {
		ts: 1700000000, uptime: 7200,
		cpu: { total: 100, idle: 50 },
		memory: { total: 1000, free: 500, available: 600, buffers: 10, cached: 20 },
		traffic: o.traffic || [],
		leases: [],
		clients: o.clients ? [ { mac: 'aa:bb:cc:dd:ee:01', ip: '192.168.5.147', host: 'pc', source: 'dhcp' } ] : [],
		uplink: o.wan ? { connected: true, device: 'wwan0', ip: '10.0.0.2/8', gateway: '10.0.0.1' } : { connected: false, device: '', ip: '', gateway: '' },
		uplinks: o.wan ? [ { device: 'wwan0', connected: true, ip: '10.0.0.2/8', gateway: '10.0.0.1', rx: 100, tx: 50 } ] : [],
		carrier: { name: '中国联通' },
		signal: { rsrp: o.signal ? -89 : 0 },
		caps: snapCaps(o),
		thermal: [], fan: { rpm: -1, pwm: -1 }, conntrack: 5
	};
}

const ids = arr => arr.map(x => x.id);
const present = arr => arr.filter(x => x.node != null).map(x => x.id);
const classes = () => Object.keys(BODY_CLASSES).sort();

/* ---------------- 1. catalog ---------------- */
console.log('== 部件目录 ==');
const catalog = req('view.dashboard.sd.catalog');
check('声明 20 个部件', catalog.widgets.length, 20);
check('cards 10 个', catalog.widgets.filter(w => w.slot === 'cards').length, 10);
check('charts 5 个', catalog.widgets.filter(w => w.slot === 'charts').length, 5);
check('tabs 5 个', catalog.widgets.filter(w => w.slot === 'tabs').length, 5);

const decl = catalog.declare();
check('声明保留 hidden 标记', decl.filter(d => d.hidden).map(d => d.slot + ':' + d.id).sort(),
	[ 'cards:dhcp', 'cards:load', 'cards:wifi', 'charts:distribution', 'charts:signal', 'charts:traffic', 'tabs:wifi' ]);
check('标题保持干净（无后缀）', decl.every(d => d.title.indexOf(' · ') < 0), true);

/* ---------------- 2. 官方 include 降级 ---------------- */
console.log('== 官方 include 降级 ==');
const registry = req('view.dashboard.sd.registry');
check('官方 widgets 被清空', Object.keys(OFFICIAL).map(k => OFFICIAL[k].widgets.length), [ 0, 0, 0, 0, 0 ]);
check('官方 available 返回 false', Object.keys(OFFICIAL).map(k => OFFICIAL[k].available()), [ false, false, false, false, false ]);
check('我们的 widgets 声明 20 条', registry.widgets.length, 20);
req('view.dashboard.include.50-cellular');
const entryFile = path.join(MODROOT, 'view/dashboard/include/50-cellular.js');
check('入口模块返回构造函数（LuCI 会 new 它）', typeof RAW[entryFile], 'function');
check('入口实例化后带 widgets 声明', cache[entryFile].widgets.length, 20);

/* ---------------- 3. 场景矩阵 ---------------- */
const S = snap({ wan: true, clients: true, wifi: true, wifiClients: true, modem: true, signal: true });

function renderWith(s, reset) {
	for (const k of Object.keys(BODY_CLASSES)) delete BODY_CLASSES[k];
	return registry.render({ snap: s, official: [ { stub: 1 }, { stub: 1 }, { stub: 1 }, { stub: 1 }, { stub: 1 } ] });
}

console.log('== 全部可用 ==');
let r = renderWith(S);
check('卡片全部有内容', present(r.cards).sort(),
	[ 'cell-signal', 'cellular', 'cpu', 'dhcp', 'internet', 'load', 'memory', 'traffic-usage', 'uptime', 'wifi' ].sort());
check('图表全部有内容', present(r.charts).sort(),
	[ 'distribution', 'signal', 'system', 'traffic', 'wan' ].sort());
check('标签全部可见', classes(), []);
check('互联网卡用我们的实现（非官方）', r.cards.filter(c => c.id === 'internet')[0].node.kind, 'kpi');
check('WAN 图用我们的实现', r.charts.filter(c => c.id === 'wan')[0].node.kind, 'card');
check('系统卡沿用官方内容', r.cards.filter(c => c.id === 'uptime')[0].node, 'UPTIME');

/* 单条在线链路时，互联网详情不应再套一层「5G cellular」二级标签 */
const providers = req('view.dashboard.sd.providers');
const oneTab = providers.tab('internet', S, { count: { clients: 0 } });
const detailKids = oneTab.content.children || [];
check('单条链路无二级标签（无 cbi-tabmenu）',
	detailKids.some(k => k.tag === 'ul'), false);
check('详情第一块是链路上报表', detailKids[0] && detailKids[0].tag, 'table');

/* 多条在线链路：用官方 dashboard-net-grid 卡片网格（与无线标签页同款） */
const twoSnap = Object.assign({}, S, {
	uplinks: [
		{ device: 'wwan0', connected: true, ip: '10.0.0.2/8', gateway: '10.0.0.1', rx: 100, tx: 50 },
		{ device: 'wan', connected: true, ip: '192.168.1.2/24', gateway: '192.168.1.1', metric: 20, rx: 9, tx: 3 }
	]
});
const twoTab = providers.tab('internet', twoSnap, { count: { clients: 1 } });
const grid = (twoTab.content.children || [])[0];
check('多链路使用 dashboard-net-grid', grid && grid.attrs && grid.attrs.class, 'dashboard-net-grid');
check('每条链路一张卡', (grid.children || []).length, 2);

console.log('== 断网（无默认路由）==');
r = renderWith(snap({ clients: true, wifi: true, wifiClients: true, modem: true, signal: true }));
check('互联网卡隐藏', present(r.cards).includes('internet'), false);
check('WAN 图隐藏', present(r.charts).includes('wan'), false);
check('系统类不受影响', present(r.cards).includes('uptime') && present(r.charts).includes('system'), true);
check('互联网标签隐藏', classes().includes('sd-hide-tab-internet'), true);

console.log('== 无在线设备 ==');
r = renderWith(snap({ wan: true, wifi: true, wifiClients: true, modem: true, signal: true }));
check('DHCP 卡隐藏', present(r.cards).includes('dhcp'), false);
check('DHCP 标签隐藏', classes().includes('sd-hide-tab-dhcp'), true);
check('互联网仍在', present(r.cards).includes('internet'), true);

console.log('== 无线未启用 ==');
r = renderWith(snap({ wan: true, clients: true, modem: true, signal: true }));
check('无线卡/图隐藏', present(r.cards).includes('wifi') || present(r.charts).includes('distribution'), false);
check('无线标签隐藏', classes().includes('sd-hide-tab-wifi'), true);

console.log('== 全部不可用 ==');
r = renderWith(snap({}));
check('仅系统类保留', present(r.cards).sort(), [ 'cpu', 'load', 'memory', 'uptime' ].sort());
check('图表仅系统负载', present(r.charts), [ 'system' ]);
check('三个标签全隐藏', classes(), [ 'sd-hide-tab-dhcp', 'sd-hide-tab-internet', 'sd-hide-tab-wifi' ]);

console.log('== 恢复后自动回来 ==');
r = renderWith(S);
check('状态类全部清除', classes(), []);
check('卡片恢复', present(r.cards).length, 10);
check('图表恢复', present(r.charts).length, 5);

console.log('\n---- 通过 ' + pass + ' / 失败 ' + fail + ' ----');
process.exit(fail ? 1 : 0);
EOF
