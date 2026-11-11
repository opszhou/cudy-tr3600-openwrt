# 分支与版本策略（fzs_5gcpe-p3）

## 三个概念别混

| 概念 | 例子 | 作用 |
|---|---|---|
| **上游分支** `branch` | `openwrt-25.12` | 决定**补丁目录**：`devices/<dev>/patches/openwrt-25.12/`；也决定 ccache/dl 缓存 key |
| **checkout ref** `upstream_ref` | `v25.12.6` | 决定**源码取哪个提交**；留空=跟分支 tip |
| 设备补丁 | `0001-mediatek-filogic-add-fzs-5gcpe-p3.patch` | 同时适用于该分支的 tip 与各 tag（已实测 v25.12.6 干净应用） |

## 两种构建形态

| 形态 | 怎么跑 | 版本号（镜像元数据） | 适用 |
|---|---|---|---|
| 滚动版 | `upstream_ref` 留空 | `25.12-SNAPSHOT` | 追上游修复，随时重出 |
| **正式版** | `upstream_ref=v25.12.6` | `25.12.6` | 要"固定、可复现、版本号明确"的时候 |

两者产物内容差异通常只在 version/version.buildinfo 与镜像尾部元数据；补丁、.config、包集合完全一致。

## 为什么补丁目录不跟着 tag 走

若补丁目录也按 tag 命名（`patches/openwrt-v25.12.6/`），每出一个小版本就要复制一份补丁，且极易漂移。
现在规则是：**补丁跟着分支**（`openwrt-25.12`），tag 只影响源码 checkout。
前置校验（`scripts/verify-device.sh`）在 tag 上会真实应用一遍补丁，漂移会当场失败：
实测 `v25.12.6` → `RESULT: OK`。

## 镜像里怎么确认版本

```sh
tar -xOf openwrt-mediatek-filogic-fzs_5gcpe-p3-squashfs-sysupgrade.bin \
    sysupgrade-fzs_5gcpe-p3/CONTROL          # BOARD=fzs_5gcpe-p3
tail -c 2000 <img> | strings | tail -3        # 尾部 JSON：supported_devices + version
```

## 与 LEDE 的关系

- 现网 LEDE 是独立 fork（coolsnowwolf），版本号自成体系
- 本仓库产出的都是 **openwrt/openwrt 主线** release 分支代码：要么分支 tip，要么正式 tag
- 刷机前后可用 `cat /etc/openwrt_release` 对照（`DISTRIB_ID="OpenWrt"` / `DISTRIB_RELEASE` 25.12.x）
