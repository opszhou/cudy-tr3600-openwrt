# 构建证据记录（fzs_5gcpe-p3）

只记录**实际跑出来的、可复核的**结果，方便日后对照"这一版到底验证了什么"。

## 2026-11-11 · run 43002620681 · head `1907e7dd` · profile `lite`

| 项 | 值 |
|---|---|
| 上游 | `openwrt/openwrt` 分支 `openwrt-25.12`（tip `fd6d730`，内核 6.12.116） |
| 结论 | **success** |
| 镜像 | `openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin` |
| 体积 | 41,431,311 字节 = **39.51 MiB**（ubi 上限 112 MiB） |
| sha256 | `b26fca9aa8671f126258394c5378531a5598ade1da49126a9b3aa6da85ee8187`（与 `sha256sums` 一致） |
| manifest | 349 个包 |

### 关键包（manifest 实测）

```
qmodem 3.4.0_rc3-r1                     luci-app-qmodem-next 3.4.0_rc3-r4
luci-i18n-qmodem-next-zh-cn 26.308.08464~99553e5
luci-ssl 26.315.12466~b2e0be4           luci-base 26.315.12466~b2e0be4
luci-app-package-manager                luci-app-sysdashboard   luci-app-dufs
htop 3.5.3-r1                           curl 8.23.0-r1
kmod-mt7915e / kmod-mt7981-firmware     mt7981-wo-firmware 20260221-r1
kmod-usb3 / kmod-usb-net-qmi-wwan / kmod-usb-net-cdc-mbim
umbim / uqmi / usb-modeswitch
```

`.config` 同步复核：`CONFIG_PACKAGE_qmodem=y`、`luci-app-qmodem-next=y`、`luci-ssl=y`、`htop=y`、`curl=y`。

### 镜像内部（解包核验）

```
sysupgrade-fzs_5gcpe-p3/{CONTROL, kernel(4.5MB), root(36.9MB)}
CONTROL = BOARD=fzs_5gcpe-p3
root(squashfs):
  /usr/bin/fzs-p3-diag
  /etc/uci-defaults/{95-modem-probe, 99z-fzs-p3-presets}
  /usr/share/qmodem/{apns.json, at_commands_zh.json, cmds/…}
  /www/luci-static/resources/view/qmodem/*.js
  /lib/netifd/proto/{qmi.sh, mbim.sh, wwan.sh, qmodem_runtime.sh}
```

## 这一版之前修掉的两个"沉默故障"

1. **镜像缺 QModem/LuCI**（run 42963844794 虽 success，但 `qmodem` 不在 manifest）
   根因：`scripts/feeds update -a` 结束时 OpenWrt 会静默执行一次 `make defconfig`，
   此刻 feed 包还没安装，清单里的 feed 包被整批裁掉；后续审计以残缺文件为基准，查不出来。
   修法：`scripts/assemble-config.sh` 单一入口 + `build-device.sh` 在 feeds 就绪后**重放 .config**。
2. **审计本身不可靠**
   修法：串行预热包索引 + `.config` 字节比对（变了就 fail）、产物自检（必装包 + 体积）、
    artifact 附带 `.config`、以及 10 分钟的 `🧪 配置闸门` 工作流。

## 尚未验证（需真机）

- 实机刷入后的网口/无线/LED/按键
- 5G 模组型号与 QModem 拨号（首启 `/etc/modem-probe.txt` 给出 VID:PID 与 ATI）
- RK3566 内联口是否存在（`p3-diag` 的 `/sys/class/net` 输出可判定）

## 2026-11-12 · run 43143238132 · head `d13e53b8` · profile `lite` · **默认 192.168.5.1**

| 项 | 值 |
|---|---|
| 上游 | tag **`v25.12.6`**（`checks out CHECKOUT_REF`），补丁目录仍按分支 `openwrt-25.12` |
| 补丁 | 只有 `0001`（诊断补丁 `0002` 已禁用并入 `patches/optional/`） |
| 结论 | **success**，用时 190 分钟 |
| 镜像 | `openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin` |
| 体积 | 41,605,384 字节 = **39.68 MiB** |
| sha256 | `67cd310c12331651bee01beba057158bb5f72329759c2cd21111f88c71d392af`（与 `sha256sums` 一致） |
| 发布 | `scripts/publish-release.mjs`（**先验收后上传**）→ Release `fzs-p3-192.168.5.1` |

### 镜像内实测（解包核验，不只看清单）

```
sha256sum 镜像 = 67cd310c…  （与 Release 资产一致）
/etc/uci-defaults/99z-fzs-p3-presets:  network.lan.ipaddr='192.168.5.1'   ← 本机默认地址
/etc/uci-defaults/99-router-presets:   network.lan.ipaddr='192.168.10.1'  ← common 默认，先执行
```

uci-defaults 按文件名字典序执行，`99-router-presets`（'-'=0x2D）< `99_migrate_nikki`（'_'=0x5F）
< `99z-fzs-p3-presets`（'z'=0x7A），所以**最终生效的是 192.168.5.1**，cudy 那台仍保持 192.168.10.1。

### 构建耗时实测（纠正早前估计）

| run | 结果 | 用时 |
|---|---|---|
| 43002620681 | success | 155 分钟 |
| 43044670983 | success | **248 分钟**（最长） |
| 43143238132 | success | 190 分钟 |

> 预期值应按 **150–250 分钟**报，不再报 60–190。
