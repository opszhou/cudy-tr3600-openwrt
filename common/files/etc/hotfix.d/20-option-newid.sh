#!/bin/sh
# 开机兜底：把「开机时就已经插着的 2cb7:0110」也补一次 option 注册。
#
# /etc/hotplug.d/usb 只在热插拔时触发；开机时设备早已枚举完，不保证收到事件。
# 判定逻辑单一来源：/etc/hotplug.d/usb/20-option-newid（本脚本只负责开机重放一次）。
# hotfix 每次开机都会执行 hotfix.d/*.sh（已在 99-router-presets 里 enable），
# 因此这里不需要再注册 init.d；核心脚本是幂等的，重放不会重复写 dynids。
#
# 可测试钩子：OPTION_NEWID_SH（scripts/test-option-newid.sh 用它指向仓库里的脚本）

OPTION_NEWID_SH="${OPTION_NEWID_SH:-/etc/hotplug.d/usb/20-option-newid}"
[ -f "$OPTION_NEWID_SH" ] || exit 0
sh "$OPTION_NEWID_SH"
