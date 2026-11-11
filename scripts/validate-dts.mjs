#!/usr/bin/env node
// validate-dts.mjs -- offline structural validator for OpenWrt device DTS files.
//
// Why this exists: a full OpenWrt build needs a Linux host. This script lets us
// prove the device tree is structurally sound (parseable, references resolve,
// partitions/nvmem cells are in range, LED/button/gpio usage is sane) before
// pushing 90 minutes of CI at it.
//
// It is NOT a replacement for dtc: it does not evaluate cpp, phandle numbers or
// dt-schema bindings. It catches the mistakes that actually break a port.
//
// usage: node scripts/validate-dts.mjs <device.dts> [--dtsi-labels <file>]... [--strict]
//   --dtsi-labels  file whose "+label: node {" lines declare SoC-level labels
//                  (e.g. OpenWrt patches-*/xxx-complete-mt7981b-dtsi.patch)
import { readFileSync } from 'node:fs';

const MACROS = {
  GPIO_ACTIVE_HIGH: '0', GPIO_ACTIVE_LOW: '1',
  KEY_RESTART: '0x0198', KEY_WPS_BUTTON: '0x0211', KEY_POWER: '0x0116',
  LED_FUNCTION_WLAN: 'wlan', LED_FUNCTION_STATUS: 'status',
  LED_FUNCTION_POWER: 'power', LED_FUNCTION_INDICATOR: 'indicator',
  LED_COLOR_ID_RED: '1', LED_COLOR_ID_GREEN: '2', LED_COLOR_ID_BLUE: '3',
  MTK_DRIVE_2mA: '2', MTK_DRIVE_4mA: '4', MTK_DRIVE_6mA: '6',
  MTK_DRIVE_8mA: '8', MTK_DRIVE_10mA: '10', MTK_DRIVE_12mA: '12',
  IRQ_TYPE_LEVEL_HIGH: '4', IRQ_TYPE_LEVEL_LOW: '8', IRQ_TYPE_EDGE_RISING: '1',
};

// ---------- args ----------
const argv = process.argv.slice(2);
const dtsPath = argv.find((a) => !a.startsWith('--') && argv[argv.indexOf(a) - 1] !== '--dtsi-labels');
const labelFiles = [];
for (let i = 0; i < argv.length; i++) if (argv[i] === '--dtsi-labels') labelFiles.push(argv[++i]);
const strict = argv.includes('--strict');
if (!dtsPath) { console.error('usage: validate-dts.mjs <device.dts> [--dtsi-labels <patch>]... [--strict]'); process.exit(2); }

// Labels defined by the SoC dtsi that ships with the upstream kernel (NOT in the OpenWrt tree,
// so --dtsi-labels files cannot supply them). Keep this list per SoC: MT7981B from kernel 6.12
// arch/arm64/boot/dts/mediatek/mt7981b.dtsi. Everything else (eth/mdio_bus/spi0/uart*/wifi/xhci/
// usb_phy/...) is added by OpenWrt's patches-*/117-complete-mt7981b-dtsi.patch.
const SOC_LABELS = {
  mt7981b: ['gic', 'infracfg', 'topckgen', 'watchdog', 'pio'],
};

// ---------- dtsi label set ----------
const socArg = (() => { const i = argv.indexOf('--soc'); return i >= 0 ? argv[i + 1] : 'mt7981b'; })();
const dtsiLabels = new Set(SOC_LABELS[socArg] || []);
for (const f of labelFiles) {
  for (const line of readFileSync(f, 'utf8').split('\n')) {
    const m = line.match(/^\+?\s*([a-zA-Z_]\w*):\s+[\w,.#-]+@?[\w,.-]*\s*\{/);
    if (m) dtsiLabels.add(m[1]);
  }
}

// ---------- tokenize ----------
let text = readFileSync(dtsPath, 'utf8').replace(/\r\n/g, '\n');
const includes = [...text.matchAll(/^#include\s+[<"]([^>"]+)[>"]/gm)].map((m) => m[1]);
text = text.split('\n').filter((l) => !/^\s*#\s*(include|define|undef|if|ifdef|ifndef|else|elif|endif|pragma|error|warning)\b/.test(l)).join('\n');
text = text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
for (const [k, v] of Object.entries(MACROS)) text = text.replace(new RegExp('\\b' + k + '\\b', 'g'), v);

const DELIM = '{};=<>():';
const tokens = [];
{
  let line = 1;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '\n') { line++; continue; }
    if (/\s/.test(c)) continue;
    if (c === '"') { let j = i + 1, s = '"'; while (j < text.length && text[j] !== '"') { if (text[j] === '\\') { s += text[j]; j++; } s += text[j]; j++; } s += '"'; tokens.push({ v: s, line }); i = j; continue; }
    if (DELIM.includes(c)) { tokens.push({ v: c, line }); continue; }
    let j = i, s = '';
    while (j < text.length && !/[\s{};=<>()":]/.test(text[j])) { s += text[j]; j++; }
    tokens.push({ v: s, line }); i = j - 1;
  }
}

// ---------- parse ----------
let ti = 0;
function parseBody(name, labels, line) {
  const n = { name, labels, props: [], children: [], line };
  while (ti < tokens.length) {
    const t = tokens[ti];
    if (t.v === '}') { ti++; if (tokens[ti] && tokens[ti].v === ';') ti++; return n; }
    const ls = []; let nm = t.v, k = ti;
    while (tokens[k + 1] && tokens[k + 1].v === ':') { ls.push(tokens[k].v); nm = tokens[k + 2] ? tokens[k + 2].v : ''; k += 2; }
    if (tokens[k + 1] && tokens[k + 1].v === '=') {
      const parts = []; let j = k + 2;
      while (j < tokens.length && tokens[j].v !== ';') { parts.push(tokens[j].v); j++; }
      const raw = parts.join(' ').replace(/\s*([<>&])\s*/g, '$1');
      n.props.push({ name: nm, raw }); ti = j + 1; continue;
    }
    if (tokens[k + 1] && tokens[k + 1].v === '{') { ti = k + 2; n.children.push(parseBody(nm, ls, t.line)); continue; }
    if (tokens[k + 1] && tokens[k + 1].v === ';') { n.props.push({ name: nm, raw: '' }); ti = k + 2; continue; }
    throw new Error('syntax error at token ' + ti + ' (' + JSON.stringify(tokens[k]) + ') line ' + t.line);
  }
  throw new Error('unbalanced braces in node ' + name + ' starting line ' + line);
}

if (tokens[0] && tokens[0].v !== '/dts-v1/') throw new Error('missing /dts-v1/');
if (!tokens[2] || tokens[2].v !== '/' || tokens[3].v !== '{') throw new Error('root node expected');
ti = 4;
const root = parseBody('/', [], 1);
const overrides = [];
while (ti < tokens.length) {
  const t = tokens[ti];
  if (!t.v.startsWith('&')) throw new Error('unexpected top-level token ' + JSON.stringify(t) + ' line ' + t.line);
  if (tokens[ti + 1].v !== '{') throw new Error('override ' + t.v + ' without body');
  const ln = t.line; ti += 2;
  overrides.push({ target: t.v.slice(1), node: parseBody('&' + t.target, [], ln), line: ln });
}

// ---------- checks ----------
const errors = [], warnings = [];
const all = [];
const walk = (n) => { all.push(n); n.children.forEach(walk); };
walk(root); overrides.forEach((o) => walk(o.node));

const defined = new Map();
for (const n of all) for (const l of n.labels) { if (defined.has(l)) errors.push('duplicate label ' + l); defined.set(l, n); }
const known = (l) => defined.has(l) || dtsiLabels.has(l);

for (const o of overrides) if (!known(o.target)) errors.push('override target &' + o.target + ' is not defined in this file nor in the SoC dtsi');
for (const n of all) for (const p of n.props) for (const m of p.raw.matchAll(/&([a-zA-Z_]\w*)(?![-\w])/g))
  if (!known(m[1])) errors.push('unresolved reference &' + m[1] + ' in ' + n.name + '/' + p.name);

const get = (n, k) => { const p = n.props.find((x) => x.name === k); return p ? p.raw : undefined; };
const cells = (raw) => (raw === undefined ? [] : raw.replace(/[<>]/g, ' ').trim().split(/\s+/).filter(Boolean));
const cnum = (x) => (/^0x/i.test(x) ? parseInt(x, 16) : parseInt(x, 10)); // DTS cells are C integers: 31 means decimal 31

if (!get(root, 'model')) errors.push('root: missing model');
const compat = get(root, 'compatible');
if (!compat) errors.push('root: missing compatible');

// unit address vs reg (parent address-cells is 1 in every real device tree)
for (const n of all) {
  const m = n.name.match(/@([0-9a-fA-F]+)$/);
  if (!m) continue;
  const reg = get(n, 'reg');
  if (reg === undefined) { errors.push(n.name + ': unit address without reg'); continue; }
  const c = cells(reg).map(cnum);
  const want = parseInt(m[1], 16); // unit addresses are always hex
  if (c[0] !== want && !(c[0] === 0 && c[1] === want)) errors.push(n.name + ': unit address 0x' + m[1] + ' does not match reg 0x' + c[0].toString(16));
}

// partitions
const parts = all.filter((n) => /^partition@/.test(n.name)).sort((a, b) => parseInt(a.name.split('@')[1], 16) - parseInt(b.name.split('@')[1], 16));
let end = -1, prev = '';
for (const p of parts) {
  const c = cells(get(p, 'reg')).map(cnum);
  if (c.length !== 2) { errors.push(p.name + ': reg needs start+size'); continue; }
  const [start, size] = c;
  if (start < end) errors.push('partition ' + p.name + ' overlaps ' + prev);
  if (size === 0) errors.push('partition ' + p.name + ' has zero size');
  end = start + size; prev = p.name;
}
// flash size: sum of the last partition end must fit the chip (128MiB here)
const flash = 0x8000000;
if (end > flash) errors.push('partitions end at 0x' + end.toString(16) + ' which exceeds the 128MiB NAND');
else if (strict && flash - end > 0x1000000) warnings.push('wastes ' + ((flash - end) / 1048576).toFixed(2) + 'MiB at the end of the flash');

// nvmem cells inside their partition
for (const lay of all.filter((n) => n.name === 'nvmem-layout')) {
  const parent = all.find((p) => p.children.includes(lay));
  const psize = cells(get(parent, 'reg')).map(cnum)[1];
  if (!get(lay, 'compatible') || !/fixed-layout|fixed-cells/.test(get(lay, 'compatible'))) errors.push('nvmem-layout without fixed-layout compatible');
  for (const cell of lay.children) {
    const c = cells(get(cell, 'reg')).map(cnum);
    if (c.length !== 2) { errors.push(cell.name + ': nvmem cell needs offset+size'); continue; }
    if (c[0] + c[1] > psize) errors.push(cell.name + ': nvmem cell 0x' + c[0].toString(16) + '+0x' + c[1].toString(16) + ' exceeds parent 0x' + psize.toString(16));
  }
}
// nvmem-cells arity vs #nvmem-cell-cells
for (const n of all) {
  const raw = get(n, 'nvmem-cells');
  if (raw === undefined) continue;
  for (const r of raw.matchAll(/&([a-zA-Z_]\w*)(\s+[0-9]+)?/g)) {
    const tgt = defined.get(r[1]);
    const decl = tgt ? get(tgt, '#nvmem-cell-cells') : undefined;
    const need = decl === undefined ? 0 : cnum(cells(decl)[0]);
    const have = r[2] ? 1 : 0;
    if (need !== have) errors.push(n.name + ': &' + r[1] + ' declares ' + need + ' extra cell(s), property supplies ' + have);
  }
}
// gpio specs
for (const n of all) for (const p of n.props) {
  if (!/(^|-)gpios?$/.test(p.name)) continue;
  for (const m of p.raw.matchAll(/<&(\w+)\s+(\d+)\s+(\d+)>/g)) {
    const pin = +m[2], flags = +m[3];
    if (pin > 56) errors.push(n.name + '/' + p.name + ': gpio pin ' + pin + ' out of MT7981 range');
    if (flags !== 0 && flags !== 1) errors.push(n.name + '/' + p.name + ': gpio flags ' + flags + ' (0=active high, 1=active low)');
    if (m[1] !== 'pio') warnings.push(n.name + '/' + p.name + ': gpio controller &' + m[1] + ' is unusual (expected &pio)');
  }
}
// LEDs
for (const ledRoot of all.filter((n) => /gpio-leds/.test(get(n, 'compatible') || ''))) {
  for (const led of ledRoot.children) {
    const hasLabel = get(led, 'label') !== undefined;
    const hasFn = get(led, 'function') !== undefined;
    const hasColor = get(led, 'color') !== undefined;
    if (!hasLabel && !(hasFn && hasColor)) errors.push('LED ' + led.name + ': needs label, or function + color');
    if (hasLabel && hasFn) warnings.push('LED ' + led.name + ': both label and function set (label wins)');
  }
}
// buttons
for (const keys of all.filter((n) => /gpio-keys/.test(get(n, 'compatible') || ''))) {
  for (const b of keys.children) {
    if (get(b, 'gpios') === undefined) errors.push('button ' + b.name + ': missing gpios');
    if (get(b, 'linux,code') === undefined) errors.push('button ' + b.name + ': missing linux,code');
  }
}
// aliases -> LED labels
const aliases = root.children.find((c) => c.name === 'aliases');
if (aliases) for (const p of aliases.props) for (const m of p.raw.matchAll(/&(\w+)/g)) if (!known(m[1])) errors.push('alias ' + p.name + ' -> &' + m[1] + ' undefined');
// led-* aliases must point at a node under a gpio-leds parent
if (aliases) for (const p of aliases.props) {
  if (!/^led-/.test(p.name)) continue;
  const m = p.raw.match(/&(\w+)/); if (!m) continue;
  const tgt = defined.get(m[1]);
  const parent = tgt ? all.find((x) => x.children.includes(tgt)) : undefined;
  if (!parent || !/gpio-leds/.test(get(parent, 'compatible') || '')) errors.push('alias ' + p.name + ' -> &' + m[1] + ' is not a gpio-leds child');
}
// switch: cpu port must be wired to an ethernet node
const ports = all.find((n) => n.name === 'ports');
if (ports) {
  const cpu = ports.children.filter((c) => get(c, 'ethernet') !== undefined);
  if (cpu.length !== 1) errors.push('ports: expected exactly one cpu port with an ethernet phandle, found ' + cpu.length);
  for (const p of ports.children) if (!get(p, 'label') && get(p, 'ethernet') === undefined) errors.push(p.name + ': neither label nor ethernet');
}

// ---------- report ----------
console.log('file       : ' + dtsPath);
console.log('includes   : ' + (includes.join(', ') || '(none)'));
console.log('dtsi labels: ' + dtsiLabels.size + ' (soc=' + socArg + ' + ' + labelFiles.length + ' file(s))');
console.log('overrides  : ' + overrides.length + ' -> ' + overrides.map((o) => '&' + o.target).join(' '));
console.log('nodes      : ' + all.length);
if (parts.length) {
  console.log('partitions : ' + parts.length + ', end 0x' + end.toString(16) + ' / 0x' + flash.toString(16) + ' (' + (end / flash * 100).toFixed(1) + '% of 128MiB)');
}
for (const w of warnings) console.log('WARN  ' + w);
for (const e of errors) console.log('FAIL  ' + e);
if (errors.length) { console.log('\nRESULT: FAIL (' + errors.length + ' error(s))'); process.exit(1); }
console.log('\nRESULT: OK' + (warnings.length ? ' (' + warnings.length + ' warning(s))' : ''));
