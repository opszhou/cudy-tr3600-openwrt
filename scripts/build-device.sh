#!/usr/bin/env bash
# 一键编译指定设备的固件（本地与 CI 通用）。
# 用法: build-device.sh <repo-root> <device-id> <profile> <openwrt目录> [owner] [repo] [extra_prs]
#   openwrt 目录需已 checkout 好上游源码（fetch-depth: 0，保证补丁可三方合并）。
set -euo pipefail

ROOT="${1:?缺少 repo root}"
DEV="${2:?缺少设备ID}"
PROFILE="${3:-lite}"
OPENWRT="${4:?缺少 openwrt 目录}"
OWNER="${5:-openwrt}"
REPO="${6:-openwrt}"
EXTRA_PRS="${7:-}"

bash "$ROOT/scripts/assemble.sh" "$ROOT" "$DEV" "$PROFILE" "$OPENWRT" "$OWNER" "$REPO" "$EXTRA_PRS"

cd "$OPENWRT"
echo "==== 更新并安装 feeds ===="
./scripts/feeds update -a
./scripts/feeds install -a

echo "==== 运行公共定制脚本（feeds 就绪后）===="
if [ -f "$ROOT/common/customize.sh" ]; then
    bash "$ROOT/common/customize.sh"
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
make download "-j$(nproc)"

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
if ! make "-j$(nproc)" 2>&1 | awk -f "$ROOT/scripts/translate-make.awk" | tee "$PROG"; then
    echo "并行编译失败，改用单线程 verbose 重试以定位错误..."
    make -j1 V=s
fi

echo "==== 编译完成，产物位于: $OPENWRT/bin/targets ===="
# 此处 cwd 已是 openwrt 树，用相对路径列出产物
ls -lh bin/targets/*/
