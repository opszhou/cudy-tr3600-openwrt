# 蜂助手 FZS 5GCPE P3（MT7981B）移植说明

> 目标：把这台机器从 LEDE（coolsnowwolf，内核/驱动偏旧）迁到 **OpenWrt 主线 release 分支 openwrt-25.12**。
> 属于本仓库的第二台设备（第一台 Cudy TR3600 v1 走 `main`，两者互不影响）。

## 登录信息（首次使用先看这个）

| 项 | 值 |
|---|---|
| 管理地址 | **http://192.168.5.1** （仅本机网段，DHCP 池 `192.168.5.100`–`249`） |
| 用户名 | `root` |
| 密码 | **空**（OpenWrt 默认无密码，浏览器弹框直接回车） |
| SSH | `ssh root@192.168.5.1`（密码同样为空） |
| 主机名 | `fzs-p3` |
| WiFi | SSID `OpenWrt` / `OpenWrt_5G`，**开放热点（无密码）** |

> ⚠️ 首次登录后请立刻「系统 → 管理权」设置 root 密码，并给 WiFi 加 WPA2/WPA3。
> 开放热点 + 空密码只适合首次调试，不要长期保持。

## 1. 为什么是这个分支

| 候选 | 结论 | 理由 |
|---|---|---|
| `openwrt-25.12` | **采用** | 主线最新 release 分支，内核 6.12，apk 包管理器，有安全/驱动回补 |
| `main` | 不用 | 滚动 SNAPSHOT：版本号漂移、依赖常断，构建不可复现 |
| `openwrt-24.10` | 不用 | 内核 6.6，WiFi 固件与 mt76 驱动偏旧，与"摆脱老旧"的诉求相反 |

- `devices/fzs_5gcpe-p3/device.yml` 里 `branch: openwrt-25.12`；
- 补丁目录 `devices/fzs_5gcpe-p3/patches/openwrt-25.12/`（分支名已含 `openwrt-` 前缀时不再重复加，
  规则见 `scripts/apply-device-patches.sh`）；
- 移植补丁已对 `openwrt-25.12` 分支 tip（`fd6d730`，2026-11）实测 `git apply --check` 干净通过。

## 2. 硬件事实（全部来自现网 LEDE 设备树，已按 6.12 绑定重写）

| 项目 | 参数 |
|---|---|
| SoC | MediaTek **MT7981B**（Filogic 820，2×Cortex-A53） |
| RAM | **256 MiB**（`0x40000000 + 0x10000000`） |
| Flash | **SPI-NAND 128 MiB**（NMBM） |
| 交换 | **MT7531**（mdio reg 31，reset GPIO39，IRQ GPIO38） |
| 网口 | port1=`lan1`、port2=`lan2`、port3=`wan`、port6=cpu→gmac0（2500base-x） |
| MAC | gmac0 ← Factory `0x2a`；wan ← Factory `0x24`（`mac-base`，`#nvmem-cell-cells=1`） |
| WiFi | MT7981 内置（MT7976），eeprom ← Factory `0x0`（`nvmem-cells`，旧 `mediatek,mtd-eeprom` 已废弃） |
| 按键 | reset GPIO1、wps GPIO0（低有效） |
| LED | wifi GPIO15（`phy1tpt` 触发）、4g GPIO34、5g GPIO35（低有效） |
| 5G 模组 | USB（xhci/usb_phy）+ UART1/UART2（`uart1_1`/`uart2_1`），具体型号首启探测，见 §5 |

### 分区表（与原厂 / 现 LEDE 完全一致，换固件不动 bootloader）

| 分区 | 偏移 | 大小 |
|---|---|---|
| BL2 | 0x000000 | 1 MiB |
| u-boot-env | 0x100000 | 512 KiB |
| Factory | 0x180000 | 2 MiB（只读，含 eeprom + MAC） |
| FIP | 0x380000 | 2 MiB |
| **ubi** | 0x580000 | **112 MiB** |

分区尾部落 10.5 MiB 未使用（与原厂一致，不动它——NMBM 的 BMT 需要余量）。

## 3. 移植补丁做了什么（3 个 hunk）

`patches/openwrt-25.12/0001-mediatek-filogic-add-fzs-5gcpe-p3.patch`

1. **新增** `target/linux/mediatek/dts/mt7981b-fzs-5gcpe-p3.dts`
   - 6.12 写法：`nvmem-layout { compatible = "fixed-layout" }` + `mac-base`、`leds/common.h` 的 function/color、
     `mt65xx.h` 的 `MTK_DRIVE_8mA`、`uart1_1/uart2_1` 分组
   - 相对 LEDE 版的关键改动：`mediatek,mtd-eeprom` → `nvmem-cells=<&eeprom_factory_0>`（内核 6.9 起 mt76 只认 nvmem）
2. `target/linux/mediatek/image/filogic.mk`：新增 `Device/fzs_5gcpe-p3`
   - `UBINIZE_OPTS := -E 5`、`BLOCKSIZE 128k`、`PAGESIZE 2048`、`KERNEL_IN_UBI := 1`
   - `IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata` —— 与原厂 U-Boot 的
     "kernel 卷 + rootfs 卷" 布局同构，**不换 bootloader、不改分区**
3. `target/linux/mediatek/filogic/base-files/etc/board.d/02_network`：
   `fzs,5gcpe-p3) ucidef_set_interfaces_lan_wan "lan1 lan2" wan ;;`
   - LEDE 里写的是 `"lan1 lan2 lan3"`，但本机只有 3 个网口且第 3 个在 dts 里标 `wan`，属笔误，这里修正为 2 LAN + 1 WAN

`platform.sh` 不需要改：KERNEL_IN_UBI + tar 镜像走默认 `nand_do_upgrade`（已对照 25.12 源码确认）。

## 4. 构建（GitHub Actions）

**Actions → 🚀 编译固件 → Run workflow**

| 参数 | 值 |
|---|---|
| `device` | `fzs_5gcpe-p3` |
| `profile` | `lite`（推荐首发）/ `ultimate` |
| `upstream_branch` | 留空（用 device.yml 的 `openwrt-25.12`） |
| `with_qmanager` | 默认 false；确认真机是 Quectel 模组后再开 |
| `create_release` | 需要 Release 页就勾上 |

产物：`openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin` + `*.manifest` + `sha256sums`。

本地等价命令（需 Linux）：

```bash
git clone --depth 1 -b openwrt-25.12 https://github.com/openwrt/openwrt.git openwrt   # CI 用 fetch-depth: 0
bash scripts/verify-device.sh . openwrt fzs_5gcpe-p3          # 10 秒前置校验
bash scripts/build-device.sh . fzs_5gcpe-p3 lite openwrt
```

### 前置校验做了什么（`scripts/verify-device.sh`）

在临时 git worktree 里（不动主工作区）：

1. 逐个补丁 `git apply`（干不了就 `--3way`，与 assemble.sh 完全一致）
2. 从补丁里取出新增的 `.dts`，用 `scripts/validate-dts.mjs` 校验：语法树、`&引用` 是否可解析、
   单元地址 vs `reg`、分区连续/不越界、nvmem 单元是否落在父分区内、gpio 引脚/极性、LED 命名、交换端口
3. 校验 `filogic.mk` 里 profile 存在、`TARGET_DEVICES` 已注册、`DEVICE_DTS` 指向的 dts 真实存在
4. 用 `scripts/test-02network.sh` 把 `02_network` 拉到沙箱里跑真分支，断言 `fzs,5gcpe-p3` → `lan1 lan2` + `wan`

校验项来自 `devices/fzs_5gcpe-p3/verify.conf`（`BOARD`/`LAN`/`WAN`）。

## 5. 5G 模组：先探测，再选管理界面

LEDE 的设备树只证明模组挂在 USB + 两路 UART 上，**型号没写**。首启会跑
`/etc/uci-defaults/95-modem-probe`，把结果写到 **`/etc/modem-probe.txt`**（重启保留）：

```sh
cat /etc/modem-probe.txt     # USB VID:PID、驱动绑定、/dev/ttyUSB*、ATI 回显、相关 dmesg
```

- **QModem（默认，推荐）**：已内置 `qmodem` + `luci-app-qmodem-next`（LuCI 网络 → QModem），
  支持 Quectel / Fibocom / MeiG / SIMCom / UNISOC 等；按 §2 驱动已全协议内置（QMI/MBIM/RNDIS/ECM/NCM + AT）
- **QManager（可选）**：`dr-dolomite/QManager` —— **不是 LuCI 页面**，是独立的 Next.js Web 控制台
  （自带端口、自带 CGI 后端），**只认 Quectel AT 模组**，且与 QModem 抢同一个 AT 口。
  勾 `with_qmanager=true` 会把 v0.1.35 的 release 包（3.59 MiB，sha256 已在 Makefile 里 pin）打进镜像，
  首启由 `/etc/uci-defaults/91-qmanager-install.sh` 离线安装，日志 `/etc/qmanager-install.log`。
  ⚠️ 用 QManager 就别让 QModem 拨号（反之亦然），否则双拨/AT 抢占

## 6. 从 LEDE 刷入（真机）

> 刷机前先备份：`sysupgrade -b /tmp/lede-backup.tar.gz`，再用 scp 拉到电脑。

```sh
# 1) 传到机器
scp openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin root@192.168.x.x:/tmp/

# 2) 校验（与 Release/Artifact 里的 sha256sums 对比）
ssh root@192.168.x.x 'sha256sum /tmp/openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin'

# 3) 跨固件刷机：不保留配置（LEDE 的 /etc/config 结构与主线不同，保留只会互相打架）
ssh root@192.168.x.x 'sysupgrade -n /tmp/openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin'
```

- compatible 同为 `fzs,5gcpe-p3`、UBI 布局与 bootloader 均未改动 → 正常 sysupgrade 即可，不需要 U-Boot 网页刷写
- 刷完默认 **LAN 192.168.5.1**（`99z-fzs-p3-presets`）、主机名 `fzs-p3`、WiFi 默认开启
  （2.4G HE20 / 5G HE80，**无密码**，请自行设 WPA2/WPA3）

### 回滚 / 救砖

1. 首选：在 LuCI「系统 → 备份/升级」刷回 LEDE 的 `sysupgrade.bin`（同样走 UBI 卷，可逆）
2. 起不来：U-Boot 网页（`192.168.1.1`，网线插 lan1）+ 原厂/LEDE 的 `sysupgrade.bin`，或 TFTP 传 initramfs
3. 极端情况：串口 `115200 8N1`（UART0）+ `mtk_uboot` 的 `nmbm` 命令重建分区表

## 7. 首刷验收清单

- [ ] `lan1`/`lan2` 拿到 DHCP、`wan` 口能拨号（插路由器/光猫）
- [ ] 2.4G / 5G 热点出现，`iwinfo` 显示 `HE20`/`HE80`
- [ ] 三颗 LED：wifi（运行）、4g、5g；两个按键：reset（长按恢复出厂）、wps
- [ ] `cat /etc/modem-probe.txt` 认出模组；`ubus list | grep qmodem` 有输出
- [ ] LuCI → 网络 → QModem：能选到模组、能拨号、`ip a` 出现 `wwan0`/`usb0` 并拿到地址
- [ ] `reboot` 后配置保留、模组自动重连
- [ ] （可选）`with_qmanager=true` 的固件：`cat /etc/qmanager-install.log` 无致命错误，页面能打开

## 8. 与 RK3566 的内联口：现状、风险与取证方法

**现状（必读）**：本移植是"现网 LEDE 设备树的 1:1 主线化"，只描述了

- MT7531 `port@1`→`lan1`、`port@2`→`lan2`、`port@3`→`wan`、`port@6`→cpu（→`gmac0`，2500base-x）
- `02_network`：LAN = `lan1 lan2`，WAN = `wan`

**没有描述**的部分：MT7531 的 `port0/4/5`、MT7981 的第二路 GMAC（`gmac1` + 内部 GPHY `int_gbe_phy`）。
如果机上 RK3566 是通过其中之一与本板相连，那么：

- 现网 LEDE 同样没有描述它 → **换固件不会更差，但也不会多出这个口**；
- 若 RK3566 走的是**物理 RJ45**，把它插到 `lan1`/`lan2` 就在 LAN 桥里，功能不受影响；
- 若走**板内直连**（switch port 或 gmac1），需要额外补一段设备树 + `02_network` 才会出现在 OpenWrt 里。

### 取证：在现网 LEDE 上跑一次（不改配置）

固件已内置 `fzs-p3-diag`（`/usr/bin/fzs-p3-diag`，输出 `/tmp/fzs-p3-diag.txt`）。
老 LEDE 上没有这个脚本时，直接整段粘贴下面这条等价命令：

```sh
{ cat /proc/device-tree/model; echo; tr '\0' '\n' </proc/device-tree/compatible; \
  for d in /sys/class/net/*; do n=${d##*/}; echo "$n $(cat $d/operstate) $(cat $d/speed 2>/dev/null)"; done; \
  ip -d link show | grep -E '^[0-9]+:|dsa|master'; ip -br addr; ip neigh; \
  dmesg | grep -iE 'mt7531|mtk_soc_eth|gmac|mdio|link is up|link is down' | tail -40; \
  cat /proc/mtd; } > /tmp/p3-diag.txt 2>&1; cat /tmp/p3-diag.txt
```

判读：

| 现象 | 结论 | 需要做的 |
|---|---|---|
| `/sys/class/net` 只有 `lan1 lan2 wan`（+ lo） | 没有第 4 个 DSA 口 | RK3566 走物理口 → 插 lan1 即可，或本就没有内联 |
| 多出 `lan3`/`lan4` 或 `port@4/5` 出现在 `ip -d link` | 内联口在 MT7531 上 | 补 dts `port@4/5 { label = "lan3"; ... }` + `02_network` 加进 LAN 桥 |
| `dmesg` 出现 `15100000.ethernet`/`eth1` 或 `int_gbe_phy` link up | 走的是 `gmac1` | 补 `gmac1 + int_gbe_phy` 节点，再按需给 DHCP/桥接 |
| RK3566 有 IP 且 `ip neigh` 能看到它 | 二层已通 | 同上表对号入座，若在 lan1/lan2 上则无需改动 |

拿到 `/tmp/p3-diag.txt` 后按上表补丁即可；补丁同样放
`devices/fzs_5gcpe-p3/patches/openwrt-25.12/`（命名 `0002-...`），CI 的
`verify-device.sh` 会先做 `git apply` 与 DTS 结构校验再编译。

## 9. 设备树：用真 dtc 编译验证过（不只是结构检查）

`scripts/validate-dts.mjs` 只能证明"结构自洽"；真正能证明"能编出 dtb"的是让 dtc 拿**内核 6.12 的
mt7981b.dtsi + OpenWrt 的 `117-complete-mt7981b-dtsi.patch`**去编它。做法（已在容器 `owrt-build` 跑过）：

```bash
cd /tmp && mkdir dtctest && cd dtctest
tar xf <dl>/linux-6.12.116.tar.xz --wildcards 'linux-6.12.116/arch/arm64/boot/dts/mediatek/*.dtsi' \
    'linux-6.12.116/include/dt-bindings/*' 'linux-6.12.116/include/uapi/linux/*.h'
cd linux-6.12.116 && patch -p1 < <openwrt>/target/linux/mediatek/patches-6.12/117-complete-mt7981b-dtsi.patch
cd .. && cp <openwrt>/target/linux/mediatek/dts/mt7981b-fzs-5gcpe-p3.dts .
cpp -nostdinc -undef -x assembler-with-cpp \
    -I linux-6.12.116/include -I linux-6.12.116/include/uapi \
    -I linux-6.12.116/arch/arm64/boot/dts/mediatek -I . \
    mt7981b-fzs-5gcpe-p3.dts -o p3.dts.pp
dtc -I dts -O dtb -o p3.dtb p3.dts.pp
```

结果（2026-11-11）：

- **编译成功**，产出 `p3.dtb` = 17660 字节
- 仅 3 条 warning，**全部来自 OpenWrt 的 mt7981b.dtsi**（`ice_debug` 无 reg、`ap2woccif@151a5000` 与
  `syscon@151a5000` 单元地址重复、efuse 内 `usb3-rx-imp@8c8` 重复），与我们这台设备的节点无关
- 反编译回 dts 逐项核对：
  - `model = "FZS 5GCPE P3"`，`compatible = "fzs,5gcpe-p3", "mediatek,mt7981"`
  - `memory@40000000` = `0x40000000 + 0x10000000`（256 MiB）
  - 分区：`BL2 / u-boot-env / Factory / FIP / ubi` 齐全
  - 交换：`port@1/2/3/6`，cpu 口 `ethernet = <&gmac0>` + `phy-mode = "2500base-x"`
  - LED 别名：`led-boot/failsafe = &led_wifi`

> 也就是说：**设备树这关不是"看起来对"，是真的能编成 dtb**；剩余风险只在硬件细节（GPIO 极性、内联口）与运行时。
