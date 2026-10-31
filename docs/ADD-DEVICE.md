# 添加新路由器

新增一台路由器 = 在 `devices/` 下新建目录 + 改 3 处，**不碰 workflows 和共用脚本**。

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
- 设备特有补丁：`devices/<设备>/patches/openwrt-<分支>/`，命名顺序 `0xxx 本地基础 < pr<PR号> < 9xxx PR后修正`

## 注意

- 不同设备可以锁不同上游分支（device.yml 的 `branch`），互不影响
- 若新设备官方主线已支持（无需 PR），补丁目录留空即可直接编译
