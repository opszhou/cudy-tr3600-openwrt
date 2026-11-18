#!/usr/bin/env bash
# 公共定制脚本：在 openwrt 根目录下执行（feeds 安装之后、defconfig 之前，每次构建都会运行）。

# 修改默认 LAN IP（已由 uci-defaults 预设实现为 192.168.10.1，见 common/files/etc/uci-defaults/99-router-presets；
# 如需构建期修改而非首启修改，可取消下行注释）
# sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate

# 修改默认固件名称显示
# sed -i 's/OpenWrt/MyWrt/g' package/base-files/files/bin/config_generate

# 修改默认主题为 Argon（仅当本组合预装了该主题时才替换，避免影响精简组合）
if grep -q '^CONFIG_PACKAGE_luci-theme-argon=y' .config 2>/dev/null \
   && [ -f feeds/luci/collections/luci/Makefile ]; then
    sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile
fi

# ---- ndisc6：已在 common/configs/modem.list 用 choice 关闭（不再参与构建）----
# 背景：qmodem feed 的 ndisc6 1.0.2 源 remlab.net 已 410；升到 Debian 池 1.0.8 后
#       又因 src/trace-tcp.c 用 C11 alignas、而该包带 -std=c99 编译失败（run#17）。
# 恢复：修 trace-tcp.c 的 alignas（改 __attribute__((aligned))），choice 改回 INCLUDE_ndisc6。

# ---- QModem nat=2：拨号固定下发网桥模式，保住 USB + 网口双路 ----
# 上游 at_dial() 每次拨号发 AT+QCFG="nat",1，会把手工设的 nat=2 写回 1，
# 下一次重拨 / 模组重启后双路失效。改法与影响面见 scripts/apply-qmodem-nat2.sh。
# 该脚本幂等，且源码格式不符时直接构建失败，不静默跳过。
# 注意：本脚本在 openwrt 根目录下执行，仓库路径必须由脚本自身位置反推，
#       不能用调用方的相对路径（CI 传 "." 在 cd 进 openwrt 后会错位）。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -f "$ROOT/scripts/apply-qmodem-nat2.sh" ]; then
    echo "错误: 缺少 scripts/apply-qmodem-nat2.sh" >&2
    exit 1
fi
bash "$ROOT/scripts/apply-qmodem-nat2.sh" "$PWD" || exit 1

# ---- QModem 版本号规范化：apk 不接受连字符预发布写法 ----
# v3.4.0-rc.3 tag 的 version.mk 是 3.4.0-rc.3，apk mkpkg 直接拒绝出包
# （run#53: package version is invalid）——编译成功、炸在打包。改法与影响面见
# scripts/apply-qmodem-apk-version.sh；格式不符同样直接构建失败。
if [ ! -f "$ROOT/scripts/apply-qmodem-apk-version.sh" ]; then
    echo "错误: 缺少 scripts/apply-qmodem-apk-version.sh" >&2
    exit 1
fi
bash "$ROOT/scripts/apply-qmodem-apk-version.sh" "$PWD" || exit 1

# ---- QModem 拨号自愈：模组处于 CFUN=0 时先把射频打开 ----
# 实测（P3 + RM500U-CNV / MBIM）：CFUN=0 时点「拨号」不会有任何效果——
#   dial() 卡在 prepare 等待循环、连接管理器 quectel-CM-M 又一直占着 dial.lock，
#   UI 再点拨号在 flock 处静默 return 1（ubus 照样回「执行成功」）。
# 补法见 scripts/apply-qmodem-cfun-fix.sh：dial() 开头先 check_cfun（CFUN≠1 就发
# AT+CFUN=1）。只在 dail 实例启动时才需要，正常 CFUN=1 时仅多一次 AT 查询。
if [ ! -f "$ROOT/scripts/apply-qmodem-cfun-fix.sh" ]; then
    echo "错误: 缺少 scripts/apply-qmodem-cfun-fix.sh" >&2
    exit 1
fi
bash "$ROOT/scripts/apply-qmodem-cfun-fix.sh" "$PWD" || exit 1

# ---- rust/host：从源码编 LLVM，不去下载 CI 预编译包 ----
# run#74（P3 切 immortalwrt 后首验）失败在 host rust：
#   downloading https://ci-artifacts.rust-lang.org/.../rust-dev-1.96.0-...tar.xz  → 404
#   ERROR: failed to download llvm from ci → package/feeds/packages/rust [host] failed to build
# 根因是 immortalwrt/packages 的 lang/rust/Makefile 写了 download-ci-llvm=true，
# 而 openwrt/packages 同一个文件写 false（所以 openwrt 两条线一直没踩到）。
# 触发条件：清单里有 Rust 实现的包才会编 host rust。2026-11 起 dufs 已换成 lighttpd
# + mod_webdav，当前各设备清单都没有 Rust 包，所以这一步通常空转（保留作防御）。
# 改法与影响面见 scripts/apply-rust-llvm.sh；上游写法变了同样直接构建失败。
if [ ! -f "$ROOT/scripts/apply-rust-llvm.sh" ]; then
    echo "错误: 缺少 scripts/apply-rust-llvm.sh" >&2
    exit 1
fi
bash "$ROOT/scripts/apply-rust-llvm.sh" "$PWD" || exit 1
