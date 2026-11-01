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

bash "$ROOT/scripts/assemble.sh" "$ROOT" "$DEV" "$PROFILE" "$OPENWRT" "$OWNER" "$REPO" "$EXTRA_PRS"

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
make defconfig

echo "==== 必选项审计（=y 项必须全部幸存，防止被 defconfig 静默丢弃）===="
missing=0
while IFS= read -r setting; do
    case "$setting" in
        CONFIG_*=y)
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

echo "==== 下载源码包 ===="
# 每个文件的 Downloading/Checking 行全部吞掉，只留失败信息（curl 错误、Download failed 不在这些前缀里）
if ! make download "-j$(nproc)" 2>&1 | awk '{ if ($0 !~ /^(Downloading|Checking) /) { print; fflush() } }'; then
    echo "错误: 源码包下载失败（见上方错误行）" >&2
    exit 1
fi
echo "✅ 源码包下载完成"

echo "==== 开始编译 ===="
# 常规编译不带 V=s（全量 echo 命令会把日志撑到 200MB+，V=s 的价值只在定位失败）。
# 失败时下面的 make -j1 V=s 重试天然就是 verbose 段，错误照样落进 CI 的 errors 通道。
# 事件日志：translate-make.awk 把 make 的静默进度行翻译成「▶ 包：动作」事件流水，
# 警告/错误原样透传，其余噪音吞掉；心跳兜底兜住单个超长目标（如内核）。
PROG="$PWD/.build-progress.log"
T0=$(date +%s)
: > "$PROG"
(
    while sleep "${HEARTBEAT_SEC:-600}"; do
        last=$(tail -n 1 "$PROG" 2>/dev/null || true)
        echo "[心跳 $(date '+%H:%M:%S')] 编译已进行 $(( ($(date +%s) - T0) / 60 )) 分钟，最近事件: ${last:-（暂无输出）}"
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

echo "==== 编译完成，产物位于: $OPENWRT/bin/targets ===="
# 此处 cwd 已是 openwrt 树，用相对路径列出产物
ls -lh bin/targets/*/
