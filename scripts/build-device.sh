#!/usr/bin/env bash
# 一键编译指定设备的固件（本地与 CI 通用）。
# 用法: build-device.sh <repo-root> <device-id> <profile> <openwrt目录> [owner] [repo] [extra_prs]
#   openwrt 目录需已 checkout 好上游源码（fetch-depth: 0，保证补丁可三方合并）。
set -euo pipefail

# 一律转绝对路径：本脚本会 cd 进 openwrt 树，相对路径（CI 传入的 "."）之后会错位——
# 曾导致 common/customize.sh 与 translate-make.awk 被静默跳过（run#15/#16 ndisc6 修复未生效）
ROOT="$(cd "${1:?缺少 repo root}" && pwd)"
DEV="${2:?缺少设备ID}"
PROFILE="${3:-lite}"
OPENWRT="$(cd "${4:?缺少 openwrt 目录}" && pwd)"
OWNER="${5:-openwrt}"
REPO="${6:-openwrt}"
EXTRA_PRS="${7:-}"
# 上游分支：显式参数 > CI 环境变量 DEV_BRANCH > device.yml（assemble.sh 内回退）
BRANCH_ARG="${8:-${DEV_BRANCH:-}}"

bash "$ROOT/scripts/assemble.sh" "$ROOT" "$DEV" "$PROFILE" "$OPENWRT" "$OWNER" "$REPO" "$EXTRA_PRS" "$BRANCH_ARG"

cd "$OPENWRT"
echo "==== 更新并安装 feeds ===="
# 输出压缩成事件：成功只留一行摘要 + feed 被忽略的警告（run#14 教训），失败才倒出错误行
FEEDS_LOG="$PWD/.feeds.log"
for step in update install; do
    if ! ./scripts/feeds "$step" -a > "$FEEDS_LOG" 2>&1; then
        echo "错误: feeds $step 失败:" >&2
        grep -aE "error:|ERROR|fatal|Ignoring" "$FEEDS_LOG" | head -20 >&2
        exit 1
    fi
done
grep -aE "Ignoring feed" "$FEEDS_LOG" | head -10 || true
rm -f "$FEEDS_LOG"
echo "✅ feeds update/install 完成"

echo "==== 运行公共定制脚本（feeds 就绪后）===="
if [ -f "$ROOT/common/customize.sh" ]; then
    echo "→ 执行 $ROOT/common/customize.sh"
    bash "$ROOT/common/customize.sh"
else
    echo "警告: 未找到 $ROOT/common/customize.sh，跳过定制步骤" >&2
    exit 1
fi

echo "==== 生成最终 .config ===="
# defconfig 前快照审计基准：种子 + 包清单里的全部 CONFIG_*=y 必选项
cp .config .config.wanted
DEFCONFIG_LOG="$PWD/.defconfig.log"
make defconfig 2>&1 | tee "$DEFCONFIG_LOG"

echo "==== 必选项审计（=y 项必须全部幸存，防止被 defconfig 静默丢弃）===="
# 差异清单（exclude.<upstream>.list）会用 "# X is not set" 覆盖前面清单里的 =y 项，
# Kconfig 以最后一条为准；审计必须同步跳过这些显式关闭的符号，否则误报「被丢弃」并中止构建
# 注意字符集必须含 - . + ：包名形如 luci-app-argon-config、kmod-tcp-bbr，
# 只用 [A-Za-z0-9_] 会一条都匹配不到（曾导致豁免失效、审计误报）
EXCLUDED_SYMS="$(grep -oE '^# (CONFIG_[A-Za-z0-9_.+-]+) is not set' .config.wanted | awk '{print $2}')"
missing=0
while IFS= read -r setting; do
    case "$setting" in
        CONFIG_*=y)
            sym="${setting%=y}"
            if [ -n "$EXCLUDED_SYMS" ] && printf '%s\n' "$EXCLUDED_SYMS" | grep -Fxq "$sym"; then
                continue   # 该上游显式关闭，不算缺失
            fi
            if ! grep -Fxq "$setting" .config; then
                echo "  被丢弃: $setting"
                # 提示同名前缀候选：区分「包被上游改名」与「包真被丢弃」
                # （如 miniupnpd 是虚拟名，defconfig 规范化为 miniupnpd-nftables）
                base="${setting%=y}"
                grep -E "^${base}" .config | sed 's/^/    现存近似项: /'
                missing=$((missing + 1))
            fi
            ;;
    esac
done < .config.wanted
if [ "$missing" -ne 0 ]; then
    echo "错误: $missing 个必选包在 defconfig 后被静默丢弃，中止构建。" >&2
    echo "常见原因: 上游已删除该包 / luci-i18n 缺 CONFIG_LUCI_LANG_zh_Hans / Kconfig 行内注释导致整行失效 / 包名拼写错误" >&2
    exit 1
fi
rm -f .config.wanted

echo "==== 依赖缺失交叉检查（提示性，不阻断）===="
# defconfig 会为所有 feed 的所有包打印「依赖不存在」警告，绝大多数与我们无关。
# 这里只挑出「包本身被选中」的那些——它们会拖到 package/install 才炸
# （如 luci-app-netspeedtest 依赖已消失的 python3-pkg-resources、turboacc 依赖 kmod-nft-fullcone）。
# 条件依赖会造成误报，故只提示不 fail。
if command -v python3 >/dev/null 2>&1 && [ -s "$DEFCONFIG_LOG" ]; then
    python3 - "$DEFCONFIG_LOG" .config <<'PY'
import re, sys
log, cfg = sys.argv[1], sys.argv[2]
sel = set()
with open(cfg, encoding='utf-8', errors='ignore') as f:
    for line in f:
        m = re.match(r'^CONFIG_PACKAGE_([A-Za-z0-9_.+-]+)=y$', line.strip())
        if m:
            sel.add(m.group(1))
risky = {}
with open(log, encoding='utf-8', errors='ignore') as f:
    for line in f:
        m = re.search(r"WARNING: Makefile '([^']+)/Makefile' has a dependency on '([^']+)', which does not exist", line)
        if not m:
            continue
        path, dep = m.group(1), m.group(2)
        pkg = path.rsplit('/', 1)[-1]
        if pkg in sel:
            risky.setdefault(pkg, set()).add(dep)
if risky:
    print("⚠ 已选中的包存在「依赖不存在」，装 rootfs 阶段可能失败（条件依赖可忽略）：")
    for pkg in sorted(risky):
        print("  %-34s ← %s" % (pkg, ", ".join(sorted(risky[pkg]))))
else:
    print("✓ 已选中的包未发现缺失依赖")
PY
fi
rm -f "$DEFCONFIG_LOG"

echo "==== 下载源码包 ===="
# 每个文件的 Downloading/Checking 行全部吞掉，只留失败信息（curl 错误、Download failed 不在这些前缀里）
dl_ok=0
for attempt in 1 2; do
    if make download "-j$(nproc)" 2>&1 | awk '{ if ($0 !~ /^(Downloading|Checking) /) { print; fflush() } }'; then
        dl_ok=1; break
    fi
    echo "⚠ 源码包下载失败（第 $attempt 次）$([ $attempt = 1 ] && echo '，10 秒后重试' || echo '，放弃')" >&2
    [ $attempt = 1 ] && sleep 10
done
[ "$dl_ok" = 1 ] || { echo "错误: 源码包下载失败（重试后仍失败，见上方错误行）" >&2; exit 1; }
echo "✅ 源码包下载完成"

echo "==== 开始编译 ===="
# 常规编译不带 V=s（全量 echo 命令会把日志撑到 200MB+，V=s 的价值只在定位失败）。
# 失败时下面的 make -j1 V=s 重试天然就是 verbose 段，错误照样落进 CI 的 errors 通道。
# 事件日志：translate-make.awk 把 make 的静默进度行翻译成「▶ 包：动作」事件流水，
# 警告/错误原样透传，其余噪音吞掉；心跳兜底兜住单个超长目标（如内核）。
PROG="$PWD/.build-progress.log"
T0=$(date +%s)
: > "$PROG"
# 心跳只报「已进行 N 分钟 + 最近事件」，不再统计包数：
# 分母/分子的口径随上游 make 输出格式漂移（前导空格、目标名变化）反复出错，
# 数字错了比没有更误导人。真实进度看「▶ 包：动作」事件流水即可。
(
    while sleep "${HEARTBEAT_SEC:-600}"; do
        last=$(tail -n 1 "$PROG" 2>/dev/null || true)
        echo "[心跳 $(date '+%H:%M:%S')] 已进行 $(( ($(date +%s) - T0) / 60 )) 分钟，最近事件: ${last:-（暂无输出）}"
    done
) &
HB_PID=$!
trap 'kill "$HB_PID" 2>/dev/null || true; rm -f "$PROG"' EXIT
# stdbuf -oL：make 的输出接管道时是块缓冲（4KB），事件要攒够一块才出现，
# 造成日志看起来「卡在某个包上不动」。强制行缓冲后进度实时可见。
if ! stdbuf -oL -eL make "-j$(nproc)" 2>&1 | awk -f "$ROOT/scripts/translate-make.awk" | tee "$PROG"; then
    echo "并行编译失败，改用单线程 verbose 重试以定位错误..."
    make -j1 V=s
fi

# ccache 命中率：判断缓存是否真的有用（决定要不要进一步缓存工具链目录）
CCBIN="$OPENWRT/staging_dir/host/bin/ccache"
if [ -x "$CCBIN" ]; then
    echo "==== ccache 统计 ===="
    CCACHE_DIR="$OPENWRT/.ccache" "$CCBIN" -s 2>/dev/null | grep -Ei "cache hit|cache miss|hit rate|cache size|files in cache" | head -8 || true
fi

# ccache 命中率：判断缓存是否真的有用（决定要不要进一步缓存工具链目录）
CCBIN="$OPENWRT/staging_dir/host/bin/ccache"
if [ -x "$CCBIN" ]; then
    echo "==== ccache 统计 ===="
    CCACHE_DIR="$OPENWRT/.ccache" "$CCBIN" -s 2>/dev/null | grep -Ei "hit rate|cache hit|cache miss|cache size" | head -6 || true
fi

echo "==== 编译完成，产物位于: $OPENWRT/bin/targets ===="
# 此处 cwd 已是 openwrt 树，用相对路径列出产物
ls -lh bin/targets/*/
