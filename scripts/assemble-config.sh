#!/usr/bin/env bash
# 只负责"把 .config 组装出来"：种子 → 全局清单 → 上游差异 → 设备差异 → 可选 QManager。
#
# 为什么单独拆出来：OpenWrt 的 scripts/feeds 在 `feeds update` 之后会**静默**执行一次
# `make defconfig`（见 scripts/feeds 里 system("$mk defconfig ...")，输出全丢进 /dev/null）。
# 那一刻 feed 包还没安装进 package/feeds、索引里也看不到它们，于是 kconfig 把清单里的
# feed 包（qmodem / luci-ssl / htop / curl / luci-i18n-* …）**全部裁掉**，且不留痕迹：
#   - .config 从 84 行"种子+清单"变成 kconfig 生成的 734 行
#   - 之后 defconfig 的"必选项审计"自然查不出丢包（基准文件已经是残缺的）
# 2026-11-11 fzs-p3 就是这样编出了没有 QModem 的镜像。
# 因此 .config 必须在 feeds update/install 之后**重放一次**——本脚本就是那个唯一入口。
#
# 用法: assemble-config.sh <repo-root> <device-id> <profile> <openwrt目录>
set -euo pipefail

ROOT="${1:?缺少 repo root}"
DEV="${2:?缺少设备ID}"
PROFILE="${3:-lite}"
OPENWRT="${4:?缺少 openwrt 目录}"
ROOT="$(cd "$ROOT" && pwd)"
OPENWRT="$(cd "$OPENWRT" && pwd)"

# shellcheck disable=SC2046
eval "$(bash "$ROOT/scripts/parse-device.sh" "$ROOT" "$DEV")"

echo "==== 组装 .config: 设备=$DEV profile=$PROFILE ===="
cp "$ROOT/devices/$DEV/default.seed" "$OPENWRT/.config"

case "$PROFILE" in
    lite)
        cat "$ROOT/common/configs/modem.list" >> "$OPENWRT/.config"
        cat "$ROOT/common/configs/lite.list" >> "$OPENWRT/.config"
        ;;
    ultimate)
        cat "$ROOT/common/configs/modem.list" >> "$OPENWRT/.config"
        cat "$ROOT/common/configs/lite.list" >> "$OPENWRT/.config"
        cat "$ROOT/common/configs/proxy.list" >> "$OPENWRT/.config"
        cat "$ROOT/common/configs/extra.list" >> "$OPENWRT/.config"
        ;;
    *)
        echo "错误: 未知 profile: $PROFILE（可选 lite/ultimate）" >&2
        exit 1
        ;;
esac

# 上游差异（该上游没有/冲突的包）
case "${UPSTREAM_REPO:-}" in
    "") ;;
    *)
        if [ -f "$ROOT/upstreams/$UPSTREAM_REPO/exclude.list" ]; then
            echo "应用上游差异清单: upstreams/$UPSTREAM_REPO/exclude.list"
            cat "$ROOT/upstreams/$UPSTREAM_REPO/exclude.list" >> "$OPENWRT/.config"
        fi
        ;;
esac

# 设备差异：add 可重新启用被 exclude 关掉的包，remove 拥有最终决定权
for f in add remove; do
    if [ -f "$ROOT/devices/$DEV/configs/$f.list" ]; then
        echo "应用设备差异清单: devices/$DEV/configs/$f.list"
        cat "$ROOT/devices/$DEV/configs/$f.list" >> "$OPENWRT/.config"
    fi
done

# 可选增强：QManager 载荷（Quectel 专用独立 Web 控制台，默认关闭）
case "${QMANAGER:-0}" in
    1|true|TRUE|yes)
        if [ -f "$ROOT/devices/$DEV/configs/qmanager.list" ]; then
            echo "启用 QManager 载荷: devices/$DEV/configs/qmanager.list"
            cat "$ROOT/devices/$DEV/configs/qmanager.list" >> "$OPENWRT/.config"
        else
            echo "警告: QMANAGER=1 但 devices/$DEV/configs/qmanager.list 不存在" >&2
        fi
        ;;
esac
echo "==== .config 组装完成: $(grep -cE '^CONFIG_[A-Za-z0-9_.+-]+=y$' "$OPENWRT/.config" || true) 个 =y 项 ===="
