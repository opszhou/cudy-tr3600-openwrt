#!/usr/bin/env bash
# 一键编译指定设备的固件（本地与 CI 通用）。
# 用法: build-device.sh <repo-root> <device-id> <profile> <openwrt目录> [owner] [repo] [extra_prs]
#   openwrt 目录需已 checkout 好上游源码（fetch-depth: 0，保证补丁可三方合并）。
set -euo pipefail

ROOT="${1:?缺少 repo root}"
DEV="${2:?缺少设备ID}"
PROFILE="${3:-standard}"
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
make defconfig

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
