# cudy-tr3600-openwrt

<p>
  <img alt="License" src="https://img.shields.io/badge/license-GPL--2.0-blue">
  <img alt="CI" src="https://img.shields.io/badge/CI-GitHub_Actions-2088FF?logo=githubactions&logoColor=white">
  <img alt="Device" src="https://img.shields.io/badge/device-Cudy_TR3600_v1-red">
  <img alt="OpenWrt" src="https://img.shields.io/badge/OpenWrt-mediatek%2Ffilogic-00B5E2">
</p>

基于 GitHub Actions 的 OpenWrt 云编译仓库，当前支持 **Cudy TR3600 v1**（MT7987B + MT7990）。
不 fork 源码树——官方 PR 以补丁形式入库，设备配置抽离、公共配置共用，新增路由器只需复制一个目录。

## ✨ 特性

- **🔀 官方 PR 一键合并** — 填 PR 号跑一次工作流，补丁自动落盘入库、自动触发编译；冲突的 PR 会生成 diff artifact 供人工处理
- **🧩 多设备架构** — 路由器特有配置收敛到 `devices/<设备>/`，feeds / 包组合 / 脚本全部共用，workflows 零改动
- **📶 内置 QModem 随身 WiFi 支持** — USB RNDIS / QMI / NCM / MBIM 全驱动 + LuCI 管理界面（qmodem-next）
- **⚙️ 两档包组合** — `lite`（精简实用，默认）/ `ultimate`（全能），一键切换
- **⚡ ccache 加速** — 二次构建约 60 分钟，首编约 90 分钟

## 📦 支持的设备

| 设备 | Target | 上游分支 | 默认 PR |
|------|--------|----------|---------|
| Cudy TR3600 v1 | `mediatek/filogic` | `main` | #25860 设备支持 + #25996 EEE 修复 |

## 🚀 快速开始

> ⚠️ 首次编译必须先跑「合并官方 PR」，否则只会产出 mediatek/filogic 通用镜像。

1. **Actions → 🔀 合并官方 PR → Run workflow** — 设备选 `cudy_tr3600-v1`，PR 号留空（自动合并默认 PR 列表），完成后自动触发编译
2. **Actions → 🚀 编译固件** — 选设备与包组合（默认 `lite`）
3. 在 Run 页面下载 **Artifacts**（`openwrt-<设备>-<组合>`），或勾选 `create_release` 直接发 Release
4. **刷机** — 先刷 Cudy 官方中间固件，再在 LuCI 升级页刷 sysupgrade 固件

详细参数、PR 组合备忘与刷机步骤见 **[docs/BUILD.md](docs/BUILD.md)**。

## 🗂️ 文档

| 文档 | 内容 |
|------|------|
| [docs/BUILD.md](docs/BUILD.md) | 云编译工作流详解、PR 组合备忘、刷机指南、本地编译 |
| [docs/PACKAGES.md](docs/PACKAGES.md) | 包组合明细、开机预设、自定义包与 feeds |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 目录结构、多设备设计、补丁机制与命名规则 |
| [docs/ADD-DEVICE.md](docs/ADD-DEVICE.md) | 添加新路由器（复制目录、改 3 个文件即可） |

## 🧩 包组合一览

| 组合 | 定位 | 说明 |
|------|------|------|
| **lite** | 精简实用（默认） | QModem 随身 WiFi 全套 + 中文化 LuCI + Argon 主题 + turboacc 硬件加速 + nikki 代理等 |
| **ultimate** | 全能 | lite 全部 + tailscale + mwan3 多 WAN + netdata + filebrowser 等 |

完整包清单与开机预设见 **[docs/PACKAGES.md](docs/PACKAGES.md)**。

## 🏗️ 设计理念

- **补丁入库，不 fork 源码** — 官方 PR 合并后删除对应 `pr*.patch` 即回归官方源码，可复现、无漂移
- **设备与公共分离** — `devices/<设备>/` 只放该机器的元数据、种子与补丁，其余全在 `common/` 共享
- **CI 与本地同一套脚本** — `scripts/` 下的组装/合并/编译脚本两边通用

架构细节见 **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**。

## 📄 许可证

本仓库自身内容遵循 [GPL-2.0](LICENSES/GPL-2.0)。
第三方组件：QModem 为 MPL-2.0，Nikki 为 GPL-3.0，kenzok8 插件以各自仓库为准。
