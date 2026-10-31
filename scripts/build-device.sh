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
            grep -Fxq "$setting" .config || { echo "  被丢弃: $setting"; missing=$((missing + 1)); }
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
if ! make "-j$(nproc)" V=s; then
    echo "并行编译失败，改用单线程重试以定位错误..."
    make -j1 V=s
fi

echo "==== 编译完成，产物位于: $OPENWRT/bin/targets ===="
# 此处 cwd 已是 openwrt 树，用相对路径列出产物
ls -lh bin/targets/*/
