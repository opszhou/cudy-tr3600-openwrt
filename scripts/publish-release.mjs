#!/usr/bin/env node
// publish-release.mjs —— 只有"验过"的构建才允许发 Release。
//
// 为什么要有它：Release 是别人会直接拿去刷的东西，"构建成功"不等于"产物可用"
// （本项目就出过 success 但镜像里没有 QModem 的事故）。所以发布必须走同一条验收链：
//   1) 先调 scripts/verify-artifact.mjs（体积 / sha256sums 一致性 / manifest 必装包）
//   2) 任一检查失败 → 拒绝发布并原样退出，绝不"先发了再说"
//   3) 通过后才创建/复用 Release 并上传 bin / initramfs / manifest / sha256sums
//
// 用法:
//   node scripts/publish-release.mjs --run 43002620681 --tag fzs-p3-v25.12.6 --name "..."
//   node scripts/publish-release.mjs --run 43002620681 --tag ... --prerelease
// 环境变量: GITHUB_TOKEN / GH_TOKEN（缺省读 ~/.git-credentials）
import { execFileSync } from 'node:child_process';
import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const arg = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const RUN = arg('--run');
const TAG = arg('--tag');
const NAME = arg('--name', TAG || ('run ' + RUN));
const DEVICE = arg('--device', 'fzs_5gcpe-p3');
const REPO = arg('--repo', 'opszhou/cudy-tr3600-openwrt');
const OUT = arg('--out', join(process.cwd(), '.work', 'publish-' + RUN));
const PRERELEASE = args.includes('--prerelease');
if (!RUN || !TAG) { console.error('用法: publish-release.mjs --run <run_id> --tag <tag> [--name ...] [--prerelease]'); process.exit(2); }

function token() {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN;
  if (process.env.GH_TOKEN) return process.env.GH_TOKEN;
  const p = join(homedir(), '.git-credentials');
  const m = existsSync(p) && readFileSync(p, 'utf8').match(/https:\/\/([^:]+):([^@]+)@github\.com/);
  if (m) return m[2];
  throw new Error('找不到 GitHub token');
}
const TOKEN = token();
const H = { Authorization: 'Bearer ' + TOKEN, Accept: 'application/vnd.github+json', 'User-Agent': 'dsh' };

// ---- 1) 验收（不通过就不发）----
console.log('== 验收 run ' + RUN + ' ==');
try {
  const out = execFileSync(process.execPath, [join(HERE, 'verify-artifact.mjs'), '--run', RUN, '--device', DEVICE, '--out', OUT], { encoding: 'utf8' });
  process.stdout.write(out);
  if (!/RESULT: OK/.test(out)) throw new Error('verify-artifact 未返回 OK');
} catch (e) {
  console.error('\n拒绝发布：产物未通过验收。');
  console.error(String(e.stdout || e.message).slice(-2000));
  process.exit(1);
}

// ---- 2) 找文件 ----
function walk(dir, acc = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, acc); else acc.push(p);
  }
  return acc;
}
const files = walk(OUT);
const pick = (re) => files.find((f) => re.test(f) && statSync(f).size > 0);
const bin = pick(new RegExp(DEVICE + '.*squashfs-sysupgrade.*\\.bin$'));
const initramfs = pick(new RegExp(DEVICE + '.*initramfs-kernel\\.bin$'));
const manifest = pick(new RegExp(DEVICE + '.*\\.manifest$'));
const sums = pick(/sha256sums$/);
if (!bin) { console.error('拒绝发布：找不到 sysupgrade 镜像'); process.exit(1); }

// ---- 3) 创建/复用 Release 并上传 ----
async function api(path, init) {
  const r = await fetch('https://api.github.com' + path, { headers: H, ...init });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
let relId = null, relUrl = null, uploadUrl = null;
const existing = await api('/repos/' + REPO + '/releases/tags/' + TAG);
if (existing.status === 200) {
  if (!existing.body.assets || existing.body.assets.length === 0) {
    relId = existing.body.id; relUrl = existing.body.html_url; uploadUrl = existing.body.upload_url;
    console.log('复用空 Release: ' + relUrl);
  } else {
    console.error('拒绝发布：tag ' + TAG + ' 的 Release 已有 ' + existing.body.assets.length + ' 个资产；请换 tag，避免新旧固件混在一起。');
    process.exit(1);
  }
} else {
  const created = await api('/repos/' + REPO + '/releases', { method: 'POST', headers: { ...H, 'Content-Type': 'application/json' },
    body: JSON.stringify({ tag_name: TAG, name: NAME, prerelease: PRERELEASE,
      body: [
        '## 蜂助手 FZS 5GCPE P3 · OpenWrt 主线（openwrt-25.12，内核 6.12）',
        '',
        '### 登录方式（重要）',
        '- 管理地址：**http://192.168.5.1**（DHCP 池 192.168.5.100–249）',
        '- 用户名：`root`',
        '- 密码：**空**（OpenWrt 默认无密码，浏览器弹框直接回车）',
        '- SSH：`ssh root@192.168.5.1`（密码同样为空）',
        '- 主机名 `fzs-p3`；WiFi SSID `OpenWrt` / `OpenWrt_5G`，**开放热点（无密码）**',
        '',
        '> ⚠️ 首次登录后请立刻到「系统 → 管理权」设置密码，并给 WiFi 加 WPA2/WPA3。',
        '',
        '### 刷机',
        '```sh',
        'scp openwrt-mediatek-filogic-fzs_5gcpe-p3-lite-squashfs-sysupgrade.bin root@<旧IP>:/tmp/',
        'ssh root@<旧IP> \'sysupgrade -n /tmp/openwrt-mediatek-filogic-fzs_5gcpe-p3-lite-squashfs-sysupgrade.bin\'',
        '```',
        '必须加 `-n`（不保留配置）。刷完地址变成 **192.168.5.1**。',
        '',
        '### 验收',
        '- 由 `scripts/publish-release.mjs` 自动发布：**先**跑 `verify-artifact.mjs`（体积 / sha256sums 一致性 / manifest 必装包），RESULT=OK 才允许上传',
        '- run: ' + RUN + ' · 设备: ' + DEVICE,
        '',
        '### 已知事项',
        '- 5G 模组 Quectel **RM500U-CNV**（UNISOC）：走 ECM/MBIM，**不要选 QMI**；LuCI → 网络 → QModem',
        '- 网口 `lan1`/`lan2`/`wan` 是 DSA 端口，`@eth0` 只是 conduit',
      ].join('\n'),
}) });
  if (created.status !== 201) { console.error('创建 Release 失败:', JSON.stringify(created.body).slice(0, 300)); process.exit(1); }
  relId = created.body.id; relUrl = created.body.html_url; uploadUrl = created.body.upload_url;
  console.log('已创建 Release: ' + relUrl);
}
for (const f of [bin, initramfs, manifest, sums].filter(Boolean)) {
  const name = f.split(/[\\/]/).pop();
  const buf = readFileSync(f);
  const r = await fetch('https://uploads.github.com/repos/' + REPO + '/releases/' + relId + '/assets?name=' + encodeURIComponent(name),
    { method: 'POST', headers: { ...H, 'Content-Type': 'application/octet-stream' }, body: buf });
  console.log('  ' + r.status + ' ' + name + ' (' + (buf.length / 1048576).toFixed(2) + ' MB)');
}
console.log('\n发布完成: ' + relUrl);
