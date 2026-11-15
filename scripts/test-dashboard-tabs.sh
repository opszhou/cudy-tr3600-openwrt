#!/usr/bin/env bash
# 沙箱测试：dashboard include 部件按数据显隐
#
# 直接加载 htdocs 里的 50-cellular.js（LuCI 模块语法在 Node 下合法：
# 开头那些 'require xxx'; 只是字符串表达式），注入最小 mock 后调用 render()。
#
# 关键语义（与官方 dashboard 的行为对齐）：
#   cards/charts —— id 必须始终注册，无数据时 node 为 null（官方按 id 后注册覆盖先注册，
#                   若干脆不返回该 id，官方同 id 的「未连接」部件会回填显示）
#   tabs         —— 官方不对 tabs 做 null 过滤，改用 body 状态类 + CSS 隐藏
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INC="$ROOT/common/package/luci-app-sysdashboard/htdocs/luci-static/resources/view/dashboard/include/50-cellular.js"

[ -f "$INC" ] || { echo "错误: 找不到 $INC" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "错误: 缺少 node" >&2; exit 1; }

node - "$INC" <<'EOF'
const fs = require('fs');
const path = process.argv[2];
const SRC = fs.readFileSync(path, 'utf8');

/* ---- 最小 LuCI 运行时 mock ---- */
globalThis._ = s => s;
globalThis.rpc = { declare: () => (() => Promise.resolve(null)) };
globalThis.baseclass = { extend: o => o };
globalThis.charts = {
	kpi: o => ({ kind: 'kpi', title: o.title }),
	card: o => ({ kind: 'card', title: o.title }),
	empty: () => ({ kind: 'empty' })
};
globalThis.L = { resolveDefault: (p, d) => Promise.resolve(d), dom: { content: () => {} } };

function node(tag, attrs, kids) {
	const n = {
		tag, attrs: attrs || {}, children: [], style: {},
		appendChild(c) { this.children.push(c); return c; },
		setAttribute(k, v) { this.attrs[k] = v; },
		getAttribute(k) { return this.attrs[k]; },
		removeAttribute(k) { delete this.attrs[k]; },
		setProperty() {}
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
			toggle(name, on) {
				if (on) BODY_CLASSES[name] = true;
				else delete BODY_CLASSES[name];
			}
		}
	},
	querySelector: () => null,
	querySelectorAll: () => [],
	createElementNS: () => node('svg'),
	createElement: () => node('div')
};

function load() {
	for (const k of Object.keys(BODY_CLASSES)) delete BODY_CLASSES[k];
	return new Function(SRC)();
}

let pass = 0, fail = 0;
function check(name, got, want) {
	const g = JSON.stringify(got), w = JSON.stringify(want);
	if (g === w) { pass++; console.log('  OK   ' + name); }
	else { fail++; console.log('  FAIL ' + name + '\n         期望 ' + w + '\n         实际 ' + g); }
}

const ids = arr => arr.map(x => x.id);
const present = arr => arr.filter(x => x.node != null).map(x => x.id);

function snap(o) {
	return {
		ts: 1700000000, uptime: 7200,
		cpu: { total: 100, idle: 50 },
		memory: { total: 1000, free: 500, available: 600 },
		traffic: [], leases: [],
		clients: o.clients || [],
		uplink: o.up || {},
		uplinks: o.uplinks || [],
		carrier: o.carrier || {},
		signal: o.signal || {},
		thermal: [], fan: { rpm: -1, pwm: -1 }, conntrack: 0
	};
}

const ONLINE = { connected: true, device: 'wwan0', ip: '10.0.0.2/8', gateway: '10.0.0.1' };
const OFFLINE = { connected: false, device: null, ip: '', gateway: '' };
const UPS_ON = [{ device: 'wwan0', connected: true, ip: '10.0.0.2/8', gateway: '10.0.0.1', rx: 100, tx: 50 }];
const UPS_OFF = [{ device: 'wan', connected: false, ip: '', gateway: '', rx: 0, tx: 0 }];
const CLIENTS = [{ host: 'pc', ip: '192.168.5.147', mac: 'aa:bb:cc:dd:ee:01', source: 'dhcp' }];
const SIG = { rsrp: -89, sinr: 20, mode: 'LTE', duplex: 'FDD' };
const CAR = { name: '中国联通', mcc: '460', mnc: '01', color: '#E60012' };

console.log('== 在线 + 有客户端 ==');
let r = load().render(snap({ up: ONLINE, uplinks: UPS_ON, clients: CLIENTS, signal: SIG, carrier: CAR }));
check('卡片始终注册 (id 稳定)', ids(r.cards), ['internet', 'cell-signal']);
check('卡片都有内容', present(r.cards), ['internet', 'cell-signal']);
check('图表 wan 有内容', present(r.charts), ['wan']);
check('标签两项都在', ids(r.tabs), ['internet', 'dhcp']);
check('没有隐藏状态类', Object.keys(BODY_CLASSES), []);

console.log('== 离线 + 有客户端（网络相关部件应隐藏）==');
r = load().render(snap({ up: OFFLINE, uplinks: UPS_OFF, clients: CLIENTS, signal: SIG }));
check('internet 卡 node=null（不显示也不回填官方版）', present(r.cards), ['cell-signal']);
check('wan 图表 node=null', present(r.charts), []);
check('标签数仍为 2（靠状态类隐藏）', ids(r.tabs), ['internet', 'dhcp']);
check('隐藏 internet 标签', BODY_CLASSES, { 'sd-no-internet-tab': true });

console.log('== 在线 + 无客户端 ==');
r = load().render(snap({ up: ONLINE, uplinks: UPS_ON, clients: [], signal: SIG }));
check('internet 卡在', present(r.cards), ['internet', 'cell-signal']);
check('隐藏 dhcp 标签', BODY_CLASSES, { 'sd-no-dhcp-tab': true });

console.log('== 离线 + 无客户端 ==');
r = load().render(snap({ up: OFFLINE, uplinks: UPS_OFF, clients: [], signal: {} }));
check('所有卡片都为空', present(r.cards), []);
check('两个标签都隐藏', BODY_CLASSES, { 'sd-no-internet-tab': true, 'sd-no-dhcp-tab': true });

console.log('== 无模组（无信号）==');
r = load().render(snap({ up: OFFLINE, uplinks: [], clients: [], signal: {} }));
check('信号卡 node=null', present(r.cards), []);

console.log('== 恢复连接后自动回来 ==');
const mod = load();
mod.render(snap({ up: OFFLINE, uplinks: UPS_OFF, clients: CLIENTS, signal: SIG }));
r = mod.render(snap({ up: ONLINE, uplinks: UPS_ON, clients: CLIENTS, signal: SIG, carrier: CAR }));
check('状态类全部清除', Object.keys(BODY_CLASSES), []);
check('卡片恢复', present(r.cards), ['internet', 'cell-signal']);
check('图表恢复', present(r.charts), ['wan']);

console.log('\n---- 通过 ' + pass + ' / 失败 ' + fail + ' ----');
process.exit(fail ? 1 : 0);
EOF
