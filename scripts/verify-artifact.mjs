#!/usr/bin/env node
// verify-artifact.mjs —— 把一次 GitHub Actions 构建的产物拉下来自检（不需要 git，走 api.github.com）。
//
// 为什么要它：git push 链路（github.com:443）在国内经常被掐，而 api.github.com 通常可达；
// 且"构建成功"与"能刷进去"是两件事，产物必须逐项核对：
//   1) sysupgrade 镜像存在且 < ubi 分区上限（fzs-p3 = 112 MiB）
//   2) manifest 里有必装包（QModem 全家 / WiFi 固件 / USB）
//   3) sha256sums 与镜像实际哈希一致
//
// 用法:
//   node scripts/verify-artifact.mjs --run 42963844794
//   node scripts/verify-artifact.mjs --run 42963844794 --device fzs_5gcpe-p3 --out /tmp/fw
// 环境变量: GITHUB_TOKEN / GH_TOKEN（缺省时读 ~/.git-credentials）
import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const args = process.argv.slice(2);
const arg = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const RUN = arg('--run');
const DEVICE = arg('--device', 'fzs_5gcpe-p3');
const OUT = arg('--out', join(process.cwd(), '.work', 'artifact'));
const REPO = arg('--repo', 'opszhou/cudy-tr3600-openwrt');
if (!RUN) { console.error('用法: verify-artifact.mjs --run <run_id> [--device X] [--out DIR]'); process.exit(2); }

function token() {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN;
  if (process.env.GH_TOKEN) return process.env.GH_TOKEN;
  const p = join(homedir(), '.git-credentials');
  if (existsSync(p)) {
    const m = readFileSync(p, 'utf8').match(/https:\/\/([^:]+):([^@]+)@github\.com/);
    if (m) return m[2];
  }
  throw new Error('找不到 GitHub token（GITHUB_TOKEN 或 ~/.git-credentials）');
}
const TOKEN = token();
const H = { Authorization: 'Bearer ' + TOKEN, Accept: 'application/vnd.github+json', 'User-Agent': 'dsh' };

async function api(path) {
  const r = await fetch('https://api.github.com' + path, { headers: H, redirect: 'follow' });
  return r;
}

// 1) run 概览
const run = await (await api('/repos/' + REPO + '/actions/runs/' + RUN)).json();
console.log('run ' + RUN + ': ' + run.status + '/' + run.conclusion + '  (' + run.head_sha.slice(0, 8) + ')');
if (run.status !== 'completed') { console.log('仍在运行，稍后再试'); process.exit(3); }
if (run.conclusion !== 'success') { console.log('构建未成功: ' + run.conclusion + ' —— 先看 job 日志'); process.exit(4); }

// 2) artifacts
const arts = await (await api('/repos/' + REPO + '/actions/runs/' + RUN + '/artifacts')).json();
const fw = (arts.artifacts || []).filter((a) => a.name.includes(DEVICE) && a.name.includes('snapshot'));
if (!fw.length) { console.log('没有找到 ' + DEVICE + ' 的固件 artifact'); process.exit(5); }
mkdirSync(OUT, { recursive: true });
for (const a of fw) {
  const zip = join(OUT, a.name + '.zip');
  const r = await fetch('https://api.github.com/repos/' + REPO + '/actions/artifacts/' + a.id + '/zip', { headers: H, redirect: 'follow' });
  if (!r.ok) { console.log('下载失败 ' + a.name + ': ' + r.status); continue; }
  writeFileSync(zip, Buffer.from(await r.arrayBuffer()));
  console.log('已下载 ' + a.name + ' -> ' + zip + ' (' + (a.size_in_bytes / 1048576).toFixed(1) + ' MiB)');
}

// 3) 解压（Windows 用 Expand-Archive，Linux 用 unzip）
for (const a of fw) {
  const zip = join(OUT, a.name + '.zip');
  const dir = join(OUT, a.name);
  if (process.platform === 'win32') {
    execFileSync('powershell', ['-NoProfile', '-Command', "Expand-Archive -Force -Path '" + zip + "' -DestinationPath '" + dir + "'"], { stdio: 'inherit' });
  } else {
    execFileSync('unzip', ['-o', '-q', zip, '-d', dir], { stdio: 'inherit' });
  }
}

// 4) 自检
function walk(dir) {
  const out = [];
  const st = readdirSync(dir, { withFileTypes: true });
  for (const e of st) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p)); else out.push(p);
  }
  return out;
}
let fail = 0;
for (const a of fw) {
  const dir = join(OUT, a.name);
  const files = walk(dir);
  const bin = files.find((f) => f.includes(DEVICE) && f.includes('sysupgrade') && f.endsWith('.bin'));
  const mf = files.find((f) => f.endsWith('.manifest'));
  const sums = files.find((f) => f.includes('sha256sums'));
  console.log('\n== ' + a.name + ' ==');
  if (!bin) { console.log('  FAIL 没找到 sysupgrade.bin'); fail = 1; }
  else {
    const sz = readFileSync(bin).length;
    const sha = createHash('sha256').update(readFileSync(bin)).digest('hex');
    console.log('  镜像: ' + bin.split(/[\\/]/).pop());
    console.log('  体积: ' + (sz / 1048576).toFixed(2) + ' MiB  (上限 112 MiB)');
    console.log('  sha256: ' + sha);
    if (sz >= 112 * 1024 * 1024) { console.log('  FAIL 超过 ubi 分区上限'); fail = 1; }
    if (sums) {
      const txt = readFileSync(sums, 'utf8');
      const line = txt.split('\n').find((l) => l.includes(bin.split(/[\\/]/).pop()));
      if (line && !line.includes(sha)) { console.log('  FAIL sha256sums 与实际哈希不一致'); fail = 1; }
      else if (line) console.log('  sha256sums: 一致 ✔');
    }
  }
  if (mf) {
    const txt = readFileSync(mf, 'utf8');
    for (const p of ['qmodem', 'luci-app-qmodem-next', 'kmod-mt7915e', 'mt7981-wo-firmware', 'kmod-usb3']) {
      const hit = new RegExp('^' + p + '(\\s|$)', 'm').test(txt);
      console.log('  ' + (hit ? 'OK     ' : 'MISSING') + ' ' + p);
      if (!hit) fail = 1;
    }
  } else { console.log('  FAIL 没找到 manifest'); fail = 1; }
}
console.log('\nRESULT: ' + (fail ? 'FAIL' : 'OK'));
process.exit(fail);
