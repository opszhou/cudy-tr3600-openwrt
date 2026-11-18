# fullconenat-nft —— vendored，非本仓库原创

## 这是什么

nftables 的 `fullcone` 表达式（全锥形 NAT）。out-of-tree 内核模块，编译出 `nft_fullcone.ko`，
配合打过补丁的 libnftnl 使用，**不依赖 iptables**。

只对 **UDP** 提供全锥语义，TCP 等价于 MASQUERADE（模块作者原文如此）。

## 为什么不从 feed 装

OpenWrt 官方（主仓库与 packages feed）没有这个包。`firewall4` 从 2023 年起认识
`option fullcone`，但没人提供实现它的模块，所以选项存在、功能永远不可用。
immortalwrt 自己维护了完整的一套，本目录即搬自那里。

## 来源

| 项 | 值 |
|---|---|
| 包定义 | `immortalwrt/immortalwrt` → `package/network/utils/fullconenat-nft/` |
| 上游源码 | https://github.com/fullcone-nat-nftables/nft-fullcone |
| 源码版本 | `07d93b626ce5ea885cd16f9ab07fac3213c355d9`（2023-05-17） |
| 许可 | GPL-2.0-only（`PKG_LICENSE_FILES:=LICENSE`） |

本目录只放 Makefile 与两个构建补丁，源码由 `PKG_SOURCE_PROTO:=git` 在构建时拉取。

附带的两个补丁原样保留：
- `010-fix-build-with-kernel-6.12.patch` —— 适配内核 6.12（P3 的 25.12 正好是 6.12）
- `011-honour-port-range-and-flags.patch` —— 尊重端口范围与 flags

## 光有这个包不够

全锥形需要三件同时到位，缺一不可：

1. **本包**（内核模块 `nft_fullcone.ko`）
2. **libnftnl 补丁** —— 用户态不认识 `fullcone` 表达式，`nft` 命令行会报 unknown expression
3. **firewall4 补丁** —— 让 `option fullcone` 真正生成 nft 规则

后两者放在 `common/patches/<上游>-<分支>/`，由 `scripts/apply-device-patches.sh` 的应用
补丁阶段打进源码树（见该脚本头部的目录说明）。

## 分支差异（重要）

| 上游分支 | libnftnl | 补丁状态 |
|---|---|---|
| openwrt `main` | 1.3.2 | 与 immortalwrt 同版本，补丁直接可用 |
| openwrt `openwrt-25.12` | **1.3.1** | 需要单独适配，当前**未提供** |

所以 `common/patches/` 目前只有 `openwrt-main/` 一份。25.12 上不要开
`INCLUDE_NFT_FULLCONE`，否则会编出「模块在、用户态不认识」的半残状态。
