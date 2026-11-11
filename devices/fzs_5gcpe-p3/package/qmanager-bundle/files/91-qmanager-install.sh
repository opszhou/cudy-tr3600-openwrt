#!/bin/sh
# QManager 首启离线安装（uci-defaults：只跑一次，跑完即删）
#
# 上游只提供"联网下载 → 校验 → 跑 install.sh"的路径；这里改成用镜像里已经打好的
# /usr/share/qmanager/qmanager.tar.gz，刷完机不需要外网也能装。
#
# 设计取舍：
#   - 失败不阻塞启动：QManager 是可选增强，装挂了也要能进 LuCI 用 QModem 拨号
#   - 全过程落日志 /etc/qmanager-install.log，排查不用连串口
#   - --skip-packages：上游会自己 opkg 装依赖，25.12 是 apk 且依赖已在镜像里，必须跳过

LOG=/etc/qmanager-install.log
PAYLOAD=/usr/share/qmanager/qmanager.tar.gz
WORK=/tmp/qmanager_install_tmp

{
	echo "== QManager 离线安装 $(date) =="
	if [ ! -f "$PAYLOAD" ]; then
		echo "找不到载荷 $PAYLOAD，跳过（固件未启用 with_qmanager？）"
		exit 0
	fi
	rm -rf "$WORK"
	mkdir -p "$WORK"
	if ! tar -xzf "$PAYLOAD" -C "$WORK"; then
		echo "解包失败，跳过"
		exit 0
	fi
	if [ ! -f "$WORK/qmanager_install/install.sh" ]; then
		echo "载荷结构异常（缺少 qmanager_install/install.sh），跳过"
		exit 0
	fi
	# 上游 install.sh 假定当前目录为其所在目录
	cd "$WORK/qmanager_install" || exit 0
	sh ./install.sh --skip-packages
	echo "exit=$?"
} >>"$LOG" 2>&1

rm -rf "$WORK"
exit 0
