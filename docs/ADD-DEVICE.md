# 添加新路由器

新增一台路由器 = 在 `devices/` 下新建目录 + 改 3 处，**不碰 workflows 和共用脚本**。
目录结构与补丁机制背景见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 步骤

1. **建目录**（ID 建议与 OpenWrt profile 一致，如 `xiaomi_ax3000t`）：

   ```
   devices/<新设备ID>/
   ├── device.yml
   ├── default.seed
   ├── patches/openwrt-<分支>/.gitkeep
   └── files/.gitkeep          # 可选
   ```

2. **device.yml**：

   ```yaml
   id: <新设备ID>
   target: mediatek/filogic          # 该设备的 OpenWrt target/subtarget
   profile: <CONFIG_TARGET_..._DEVICE_ 后面的名字>
   branch: main
   default_prs:                      # 该设备需要合并的官方 PR（可留空）
     - <pr号>
   ```

3. **default.seed**：只需目标选择三行 + 想改的基础包：

   ```yaml
   CONFIG_TARGET_mediatek=y
   CONFIG_TARGET_mediatek_filogic=y
   CONFIG_TARGET_mediatek_filogic_DEVICE_<profile>=y
   ```

4. 跑「合并官方 PR」（若有 PR）→ 跑「编译固件」选新设备；
   或编译时勾选 `build_all` 一次编译全部设备。

## 复用规则

- feeds（qmodem/nikki）、包组合（modem/proxy）、定制脚本、files 公共覆盖 → `common/`，所有设备共享
- 设备特有的包：建 `devices/<设备>/package/<包名>/`（会整体拷入 openwrt/package/）
- 设备特有的 /etc 配置：`devices/<设备>/files/`（覆盖在 common/files 之上）
- 设备特有补丁：`devices/<设备>/patches/openwrt-<分支>/`，命名 `0xxx 本地基础 < 1pr<PR号> 官方PR < 9xxx PR后修正`（首位数字即档位，字典序=应用顺序）

## 注意

- 不同设备可以锁不同上游分支（device.yml 的 `branch`），互不影响
- 若新设备官方主线已支持（无需 PR），补丁目录留空即可直接编译

## 跨分支设备（如 fzs_5gcpe-p3 用 openwrt-25.12，cudy 用 main）

- `device.yml` 的 `branch` 写目标分支全名；补丁目录同名（`patches/openwrt-25.12/`）
- CI 的 matrix 按设备逐 job 解析分支，两个设备互不影响；`dl`/`ccache` 缓存 key 含分支与设备，不会串味
- `common/configs/*.list` 是跨设备共用的，若某个包在目标分支上不存在/改名：
  - 包改名 → 设备 `configs/add.list` 里用新名重新启用
  - 包里没有 → 设备 `configs/remove.list` 里写 `# CONFIG_PACKAGE_xxx is not set`（构建的"必选项审计"会自动豁免）

## 可选文件：verify.conf

```sh
BOARD=fzs,5gcpe-p3     # device tree compatible[0]，02_network 按它分派
LAN="lan1 lan2"        # 期望 LAN 端口
WAN="wan"              # 期望 WAN 端口
```

有了它，`scripts/verify-device.sh` 会在编译前用沙箱跑一次 `02_network` 的真分支；
没有就跳过该项（其余校验照跑）。
