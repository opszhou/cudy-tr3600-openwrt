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
   ref: v25.12.2                     # 可选：锁 tag/commit（留空=跟分支头）。branch 仍决定补丁目录
   upstream_owner: immortalwrt       # 可选：设备默认上游（留空=openwrt，CI 输入可临时覆盖）
   upstream_repo: immortalwrt
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
- 想要正式版本号而不是 `SNAPSHOT`：加 `ref: v25.12.x` 锁 tag。分支头的版本标记永远是 SNAPSHOT，
  锁 tag 后 `/etc/openwrt_version` 才是发布号（如 `25.12.2`）。补丁仍按 `branch` 找，不用改目录
- CI 的 matrix 按设备逐 job 解析分支，两个设备互不影响；`dl`/`ccache` 缓存 key 含分支与设备，不会串味

### 设备默认上游

`upstream_owner` / `upstream_repo` 是可选的设备级默认值，优先级：

```
工作流输入 > device.yml 的 upstream_* > openwrt/openwrt
```

- 只为「固定只走某个上游」的设备准备（如 P3 要 immortalwrt 的全锥形 NAT），写进 device.yml 就不会因为派发时漏传参数而编成另一个源
- 需要按次切换上游的设备（如 cudy 在 openwrt main 与 immortalwrt master 之间切）**不要**写这两个字段
- 补丁目录不随上游变：release 分支（`openwrt-25.12`）名字本身唯一确定基线，只用分支名；滚动分支（`main`/`master`）必须带上游名区分（`openwrt-main` / `immortalwrt-master`）

### 包清单差异

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

## 必填文件：audit.conf

```sh
REQUIRED_PKGS="qmodem luci-app-qmodem-next kmod-usb3"   # 必装包，逐个在 manifest 里核对
MAX_MIB=232                                             # sysupgrade.bin 上限 = ubi 分区大小
```

`scripts/audit-image.sh` 在出 Artifact 前用它核对两件事：必装包真的进了镜像、
sysupgrade.bin 不超 ubi 分区。⛔ 必装包必须按设备写：把 MT7981 的
`kmod-mt7915e` / `mt7981-wo-firmware` 套到 MT7987B 设备上，会导致构建成功却被判失败。
文件缺失即构建失败——不允许静默跳过审计。

