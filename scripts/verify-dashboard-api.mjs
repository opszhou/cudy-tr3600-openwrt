#!/usr/bin/env node
// verify-dashboard-api.mjs -- 校验上游 luci-mod-dashboard 的接口契约
//
// 我们的面板是「扩展点」方式：不改官方文件，只往它扫描的目录加 include / sd 模块，
// 并用同 id 覆盖部件。因此强依赖官方这几处内部行为：
//   1) lib/charts.js 提供 kpi() / card() / empty()
//   2) index.js 用 found[slot] 收集部件，并用 !=null 过滤空部件（我们靠 node=null 隐藏）
//   3) lib/widgets.js 有 available() / defaults() / slots
//   4) 官方 include 的 widget id 仍包含我们要覆盖的那些
//
// ⚠️ 上游代码风格在变：25.12 是压缩成一行，master 已经 pretty-print（有空格换行）。
//    所以这里一律先去掉空白再匹配，不依赖排版。
//
// 用法:
//   node scripts/verify-dashboard-api.mjs <openwrt-root>
//   node scripts/verify-dashboard-api.mjs --dir <dashboard视图目录>
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const argv = process.argv.slice(2);
const die = (m) => { console.error('错误: ' + m); process.exit(1); };

let vd = '', root = '';
const di = argv.indexOf('--dir');
if (di >= 0) {
	vd = argv[di + 1];
	if (!vd || !existsSync(vd)) die('目录不存在: ' + vd);
}
else {
	root = argv[0];
	if (!root) die('用法: verify-dashboard-api.mjs <openwrt-root> | --dir <dir>');
	for (const cand of [
		join(root, 'feeds/luci/modules/luci-mod-dashboard/htdocs/luci-static/resources/view/dashboard'),
		join(root, 'package/feeds/luci/luci-mod-dashboard/htdocs/luci-static/resources/view/dashboard'),
		join(root, 'www/luci-static/resources/view/dashboard')
	]) {
		if (existsSync(cand)) { vd = cand; break; }
	}
	if (!vd) die('找不到 luci-mod-dashboard 的视图目录（feeds 是否已安装？）');
}

const squeeze = (p) => readFileSync(p, 'utf8').replace(/\s+/g, '');

console.log('== 管理面板接口契约校验 ==');
console.log('  目标: ' + vd);

let fail = 0;
const ok = (m) => console.log('  OK   ' + m);
const bad = (m) => { console.error('  FAIL ' + m); fail++; };

for (const f of ['lib/charts.js', 'index.js', 'lib/widgets.js'])
	if (!existsSync(join(vd, f))) die('缺少 ' + f + '（上游结构已变）');

// 1) charts API
const charts = squeeze(join(vd, 'lib/charts.js'));
for (const sym of ['kpi(', 'card(', 'empty('])
	charts.includes(sym) ? ok('charts.js 提供 ' + sym) : bad('charts.js 缺少 ' + sym);

// 2) collectSections 的收集与 null 过滤（我们隐藏卡片的机制）
const index = squeeze(join(vd, 'index.js'));
if (index.includes('found[slot]') && index.includes('!=null'))
	ok('index.js 仍用 found[slot] + !=null 过滤');
else
	bad('index.js 的部件收集/过滤逻辑已变（node=null 隐藏机制会失效）');

// 3) widgets 语义
const widgets = squeeze(join(vd, 'lib/widgets.js'));
for (const sym of ['available', 'defaults', 'slots'])
	widgets.includes(sym) ? ok('widgets.js 含 ' + sym) : bad('widgets.js 缺少 ' + sym);

// 4) 官方 include 的 widget id（排除我们自己的 99-sd-*）
const incDir = join(vd, 'include');
const ids = new Set();
for (const name of readdirSync(incDir)) {
	if (!name.endsWith('.js') || /^99-sd-/.test(name)) continue;
	const src = squeeze(join(incDir, name));
	for (const m of src.matchAll(/id:['"]([a-z-]+)['"],slot:['"]([a-z]+)['"]/g)) ids.add(m[2] + ':' + m[1]);
	for (const m of src.matchAll(/slot:['"]([a-z]+)['"],id:['"]([a-z-]+)['"]/g)) ids.add(m[1] + ':' + m[2]);
}

const REQUIRED = [
	'cards:internet', 'cards:uptime', 'cards:cpu', 'cards:memory', 'cards:dhcp', 'cards:wifi',
	'charts:wan', 'charts:system', 'charts:distribution', 'charts:signal', 'charts:traffic',
	'tabs:internet', 'tabs:system', 'tabs:resources', 'tabs:dhcp', 'tabs:wifi'
];
const missing = REQUIRED.filter((id) => !ids.has(id));
if (missing.length === 0) {
	ok('官方部件 id 齐全（' + REQUIRED.length + ' 个）');
}
else {
	bad('官方部件 id 缺失: ' + missing.join(' '));
	console.error('       实际获取到: ' + [...ids].sort().join(' '));
}

// 5) 上游版本，便于回溯漂移
if (root && existsSync(join(root, 'feeds/luci/.git'))) {
	try {
		const ver = execFileSync('git', ['-C', join(root, 'feeds/luci'), 'describe', '--always', '--tags'],
			{ encoding: 'utf8' }).trim();
		if (ver) console.log('  上游 luci feed: ' + ver);
	} catch (e) { /* 忽略 */ }
}

if (fail) {
	console.error('RESULT: FAIL（' + fail + ' 项不满足，先适配再编译）');
	process.exit(1);
}
console.log('RESULT: OK');
