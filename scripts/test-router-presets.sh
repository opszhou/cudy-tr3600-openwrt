#!/usr/bin/env bash
# 99-router-presets 的 CI 冒烟测试：stub uci/crontab，在沙箱里真实执行预设脚本并断言结果。
# 覆盖：LAN/DHCP 默认值、UPnP 安全模式、crontab 定时重启（含幂等）、BBR 两分支、5G SSID 后缀（含不二次加缀、2.4G 不动）。
# 用法: bash scripts/test-router-presets.sh   （无参数；临时目录自清理）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRESET="$ROOT/common/files/etc/uci-defaults/99-router-presets"
[ -f "$PRESET" ] || { echo "FAIL: 找不到预设脚本 $PRESET" >&2; exit 1; }

# 沙箱放在仓库 .workbuddy/tmp 下（系统 Temp 在部分环境会被安全策略拦截删除）
mkdir -p "$ROOT/.workbuddy/tmp"
SB=$(mktemp -d "$ROOT/.workbuddy/tmp/presets-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"

# ---- uci stub：扁平状态文件（节类型行不带引号，选项行带引号，与真实 uci show 输出兼容）----
cat > "$SB/bin/uci" <<'STUB'
#!/usr/bin/env bash
state="$UCI_STATE_FILE"
[ "${1:-}" = "-q" ] && shift
cmd="${1:?usage}"; shift
case "$cmd" in
  set)
    kv="$1"; key="${kv%%=*}"; val="${kv#*=}"
    val="${val#\'}"; val="${val%\'}"
    grep -vF "${key}=" "$state" > "$state.t" 2>/dev/null || :
    mv "$state.t" "$state"
    printf "%s='%s'\n" "$key" "$val" >> "$state"
    ;;
  get)
    key="$1"
    line=$(grep -F "${key}=" "$state" | head -n1)
    [ -n "$line" ] || exit 1
    out="${line#*=}"; out="${out#\'}"; out="${out%\'}"
    printf '%s\n' "$out"
    ;;
  add_list)
    kv="$1"; key="${kv%%=*}"; val="${kv#*=}"
    val="${val#\'}"; val="${val%\'}"
    printf "%s='%s'\n" "$key" "$val" >> "$state"
    ;;
  del_list|delete)
    kv="${1}"; key="${kv%%=*}"
    if [ "$cmd" = "delete" ]; then
      grep -v "^${key}" "$state" > "$state.t" 2>/dev/null || :
    else
      grep -vF "$kv" "$state" > "$state.t" 2>/dev/null || :
    fi
    mv "$state.t" "$state"
    ;;
  show)
    grep "^${1}\." "$state" 2>/dev/null || :
    ;;
  commit) : ;;
  *) exit 2 ;;
esac
STUB

# ---- crontab stub：-l 读沙箱文件；传文件名参数时复制该文件；否则读 stdin ----
cat > "$SB/bin/crontab" <<'STUB'
#!/usr/bin/env bash
f="$CRON_FILE"
case "${1:-}" in
  -l) [ -f "$f" ] && cat "$f"; exit 0 ;;
  -*) exit 0 ;;
  *)  if [ -n "${1:-}" ] && [ -f "$1" ]; then cat "$1" > "$f"; else cat > "$f"; fi; exit 0 ;;
esac
STUB
chmod +x "$SB/bin/uci" "$SB/bin/crontab"

UCI_STATE_FILE="$SB/uci.state"
CRON_FILE="$SB/crontab"
SYSCTL_CONF="$SB/sysctl.conf"
CRON_TMP="$SB/cron.tmp"
export UCI_STATE_FILE CRON_FILE SYSCTL_CONF CRON_TMP

# ---- 断言工具 ----
fails=0
assert_eq() { # <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (期望 [$2]，实际 [$3])" >&2; fails=$((fails + 1)); fi
}
assert_count() { # <描述> <期望条数> <grep模式> <文件>
    local n; n=$(grep -cE "$3" "$4" 2>/dev/null || true)
    if [ "$n" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (期望 $2 条，实际 $n 条)" >&2; fails=$((fails + 1)); fi
}
get_val() { # <键> -> 去引号的值
    local line; line=$(grep -F "$1=" "$UCI_STATE_FILE" | head -n1 || true)
    local v="${line#*=}"; v="${v#\'}"; v="${v%\'}"; printf '%s' "$v"
}

# ---- 初始 fixture：system 节 + 双频 radio（radio0=2G、radio1=5G）+ 既有 cron 任务 + dufs 配置 ----
cat > "$UCI_STATE_FILE" <<'FIX'
system.@system[0]=system
network.lan=interface
network.lan.proto=static
wireless.radio0=wifi-device
wireless.radio0.band=2g
wireless.default_radio0=wifi-iface
wireless.default_radio0.device=radio0
wireless.default_radio0.ssid=OpenWrt
wireless.default_radio0.encryption=psk2
wireless.radio1=wifi-device
wireless.radio1.band=5g
wireless.default_radio1=wifi-iface
wireless.default_radio1.device=radio1
wireless.default_radio1.ssid=Home
wireless.default_radio1.encryption=psk2
wireless.default_radio1.key=secret123
FIX
printf '0 5 * * * /usr/bin/some-existing-job\n' > "$CRON_FILE"
cat > "$SB/dufs.config" <<'FIX'
config dufs 'config'
	option enabled '0'
	option port '5000'
	option serve_path '/mnt'
FIX
export DUFS_CONF="$SB/dufs.config"

# transmission 配置（匿名节，模拟上游 /etc/config/transmission 的首行结构）
cat > "$SB/transmission.config" <<'FIX'
config transmission
	option enabled '0'
	option download_dir '/tmp/transmission/done'
FIX
export TRANS_CONF="$SB/transmission.config"
export TRANS_DL_ROOT="$SB/mnt/transmission"
export TRANS_SDA1="$SB/mnt/sda1"

# ===== 场景一：首次开机（BBR 模块在场）=====
mkdir -p "$SB/bbr-present"
PATH="$SB/bin:$PATH" BBR_SYS_DIR="$SB/bbr-present" sh "$PRESET"

assert_eq "LAN IP 默认 192.168.10.1" "192.168.10.1" "$(get_val network.lan.ipaddr)"
assert_eq "LAN 掩码 /24" "255.255.255.0" "$(get_val network.lan.netmask)"
assert_eq "DHCP 起始 .100" "100" "$(get_val dhcp.lan.start)"
assert_eq "DHCP 数量 150（.100~.249）" "150" "$(get_val dhcp.lan.limit)"
assert_eq "UPnP 安全模式开启" "1" "$(get_val upnpd.config.secure_mode)"
# dnsmasq 上游兜底：蜂窝上行/WAN 空载时没有上游，必须固定两份，否则全部查询 REFUSED
assert_eq "主机名 tr3600" "tr3600" "$(get_val system.@system[0].hostname)"
assert_eq "时区 zonename Asia/Shanghai" "Asia/Shanghai" "$(get_val system.@system[0].zonename)"
assert_eq "timezone 对应 CST-8" "CST-8" "$(get_val system.@system[0].timezone)"
assert_eq "24 小时制 h23" "h23" "$(get_val system.@system[0].clock_hourcycle)"
assert_eq "dufs 启用" "1" "$(get_val dufs.config.enabled)"
assert_eq "dufs 端口 8080" "8080" "$(get_val dufs.config.port)"
assert_eq "dufs 根目录 /mnt" "/mnt" "$(get_val dufs.config.serve_path)"
assert_eq "dufs 默认开上传" "1" "$(get_val dufs.config.allow_upload)"
assert_eq "dufs 删除权限默认关" "" "$(get_val dufs.config.allow_delete)"
assert_eq "dufs 仅 U 盘可写其余只读" "@/:ro,/sda1:rw" "$(get_val dufs.config.auth)"
# Transmission：默认 /tmp 是内存盘，预设必须迁出；无 U 盘时落 overlay
assert_eq "Transmission 开机自启" "1" "$(get_val 'transmission.@transmission[0].enabled')"
assert_eq "Transmission 下载目录迁出 /tmp（无 U 盘落 overlay）" "$SB/mnt/transmission/done" "$(get_val 'transmission.@transmission[0].download_dir')"
assert_eq "Transmission 配置目录持久化" "$SB/mnt/transmission/config" "$(get_val 'transmission.@transmission[0].config_dir')"
assert_eq "Transmission 未完成目录启用" "1" "$(get_val 'transmission.@transmission[0].incomplete_dir_enabled')"
assert_eq "5G SSID 加 _5G 后缀" "Home_5G" "$(get_val wireless.default_radio1.ssid)"
assert_eq "2.4G SSID 保持不变" "OpenWrt" "$(get_val wireless.default_radio0.ssid)"
assert_eq "2.4G 默认 WiFi7 EHT20" "EHT20" "$(get_val wireless.radio0.htmode)"
assert_eq "5G 默认 WiFi7 EHT80" "EHT80" "$(get_val wireless.radio1.htmode)"
assert_eq "2.4G 国家码 CN" "CN" "$(get_val wireless.radio0.country)"
assert_eq "5G 国家码 CN" "CN" "$(get_val wireless.radio1.country)"
assert_eq "5G 信道自动（ACS）" "auto" "$(get_val wireless.radio1.channel)"
assert_eq "5G 排除 DFS 信道" "1" "$(get_val wireless.radio1.acs_exclude_dfs)"
assert_eq "有密钥接口升级为 WPA2/WPA3 混合" "sae-mixed" "$(get_val wireless.default_radio1.encryption)"
assert_eq "混合模式 PMF 为可选" "1" "$(get_val wireless.default_radio1.ieee80211w)"
# 默认开热点（开放网络）：radio 与 AP 接口都要启用，无密钥接口清掉残留加密设置
assert_eq "2.4G radio 默认启用" "0" "$(get_val wireless.radio0.disabled)"
assert_eq "5G radio 默认启用" "0" "$(get_val wireless.radio1.disabled)"
assert_eq "2.4G AP 接口默认启用" "0" "$(get_val wireless.default_radio0.disabled)"
assert_eq "5G AP 接口默认启用" "0" "$(get_val wireless.default_radio1.disabled)"
assert_eq "无密钥接口保持开放（清掉残留加密设置）" "none" "$(get_val wireless.default_radio0.encryption)"
assert_count "BBR 行写入 sysctl" 1 "tcp_congestion_control=bbr" "$SYSCTL_CONF"
assert_count "既有 cron 任务保留" 1 "some-existing-job" "$CRON_FILE"
assert_count "定时重启 cron 恰好 1 条" 1 "touch /etc/banner && reboot" "$CRON_FILE"

# ===== 场景二：重复执行（幂等：不二次加缀、cron 不重复、BBR 分支不再触发）=====
PATH="$SB/bin:$PATH" BBR_SYS_DIR="$SB/bbr-absent" sh "$PRESET"

assert_eq "重复执行后 5G SSID 不二次加缀" "Home_5G" "$(get_val wireless.default_radio1.ssid)"
assert_count "重复执行后 cron 仍 1 条" 1 "touch /etc/banner && reboot" "$CRON_FILE"
assert_count "BBR 模块不在场时不写 sysctl" 1 "tcp_congestion_control=bbr" "$SYSCTL_CONF"

# ===== 场景三：SSD 已带后缀的 5G iface 不被改动（换个初始状态再跑一遍）=====
cat > "$UCI_STATE_FILE" <<'FIX'
wireless.radio1=wifi-device
wireless.radio1.band=5g
wireless.default_radio1=wifi-iface
wireless.default_radio1.device=radio1
wireless.default_radio1.ssid=MyWiFi_5G
FIX
: > "$SYSCTL_CONF"
PATH="$SB/bin:$PATH" BBR_SYS_DIR="$SB/bbr-present" sh "$PRESET"
assert_eq "已带 _5G 后缀的 SSID 原样保留" "MyWiFi_5G" "$(get_val wireless.default_radio1.ssid)"

# ===== 场景四：首启时 U 盘已在场（transmission 下载目录应落在盘上而不是 overlay）=====
mkdir -p "$SB/mnt/sda1"
PATH="$SB/bin:$PATH" BBR_SYS_DIR="$SB/bbr-present" sh "$PRESET"
assert_eq "有 U 盘时下载目录落在 /mnt/sda1" "$SB/mnt/sda1/transmission/done" "$(get_val 'transmission.@transmission[0].download_dir')"
if [ -d "$SB/mnt/sda1/transmission/incomplete" ]; then echo "PASS: 下载/未完成/配置目录已创建"; else echo "FAIL: 目录未创建" >&2; fails=$((fails + 1)); fi

# ===== 汇总 =====
if [ "$fails" -ne 0 ]; then
    echo "结果: $fails 项断言失败" >&2
    exit 1
fi
echo "结果: 全部断言通过"
