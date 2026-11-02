# immortalwrt-master 补丁说明

针对 **immortalwrt/immortalwrt master**（内核 6.18，与 OpenWrt main 同代）。

## 为什么可以原样复用 openwrt-main 的补丁

2026-11-03 在容器内对 immortalwrt master（浅克隆）实测验：

- `1pr25860.patch`（TR3600 设备支持）→ **干净应用**，仅 02_network 偏移 7 行、filogic.mk 偏移 62 行（上下文命中，无需改）
- `1pr25996.patch`（RTL8221B EEE 标 broken）→ **零偏移干净应用**
- `9000-tr3600-v1-hw-fixes.patch`（本地硬件修正）→ 在 25860 之后 **零偏移干净应用**

原因：immortalwrt 与 OpenWrt main 的 `target/linux/mediatek/{dts,image,filogic}` 布局完全一致，且 master 已含 `mt7987b.dtsi`、`mt7987a-glinet-gl-mt3600be.dts`（MT7987+MT7990 同款组合先例）、`mt7987-2p5g-phy-firmware`。

## 维护规矩

- 上游（immortalwrt master）若改动 `filogic.mk` / `02_network` / `mediatek_filogic` 附近上下文，重新验证 `git apply --check`；偏移可接受，冲突需重新生成
- OpenWrt 侧对应补丁更新时（如 PR 25860 被合入上游），两份目录要同步，但**不要盲目 cp**——先各自 `--check` 验证
- 本目录**不适用** device.yml 的 `default_prs` 机制（那是从 GitHub 拉 PR 用的）；这里全部是静态补丁
