# 本地编译环境（LXD 构建容器）

CI 之外的第二条验证路径。CI 一轮 60–90 分钟且要排队，本地容器可以按需反复跑、
拿真实 artifact，也能直接验证 `verify-device.sh` 这类"必须在 Linux 下才成立"的检查。

## 1. 容器

| 项 | 值 |
|---|---|
| 名称 | `owrt-build`（LXD，常驻运行） |
| 规格 | 14 vCPU / 24 GB RAM / 417 GB 可用（存储池 `lxcdata-btrfs`） |
| 系统 | Ubuntu（宿主内核 7.0），时区 Asia/Shanghai，apt 走阿里云镜像 |
| 依赖 | OpenWrt 官方 build-essential 全量清单 + `device-tree-compiler`(dtc 1.7.2) + `nodejs`(v22) + `ccache` + `jq` + `squashfs-tools` |

创建方式（LXD MCP）：`copy_container(name="owrt-build", source="agent-base")`，
再 `set_config limits.cpu=14 / limits.memory=24GB`，随后跑一次依赖安装脚本。

## 2. 目录

```
/build/repo        # 本仓库（git clone 自 GitHub，含 devices/fzs_5gcpe-p3）
/build/openwrt     # 上游 openwrt-25.12（--filter=blob:none，保留历史以支持 git apply --3way）
/build/.ccache     # 12 GB ccache 缓存，重复构建从第二次起快很多
/build/build2.log  # 构建日志（build.log 是首次失败的留档）
/root/build.sh     # 一键：verify-device.sh -> build-device.sh
```

## 3. 一键构建

```bash
# 在容器内（root）
bash /root/build.sh                       # verify + 全量构建
SKIP_VERIFY=1 bash /root/build.sh         # 跳过前置校验（已知补丁没问题时）
```

`/root/build.sh` 的核心只有两步，与 CI 完全一致：

```bash
bash scripts/verify-device.sh /build/repo /build/openwrt fzs_5gcpe-p3 openwrt-25.12 openwrt
bash scripts/build-device.sh  /build/repo fzs_5gcpe-p3 lite /build/openwrt openwrt openwrt "" openwrt-25.12
```

## 4. 容器内构建的两个坑（`/root/build.sh` 已处理）

1. **以 root 跑必须开 `FORCE_UNSAFE_CONFIGURE=1`**
   否则 `tools/tar` 这类 GNU autoconf 包在 configure 阶段直接报
   `you should not run configure as root` 而中断（首次构建就栽在这里）。
2. **重复构建要先清残留**
   `assemble.sh` 是给 CI 的干净 checkout 设计的；同一棵树上重跑时，
   若残留 `build_dir/host/<pkg>` 或 `staging_dir/host/stamp/.tools_*`，
   会得到"补丁已应用 / 工具重编"的假失败。重跑前：
   ```bash
   cd /build/openwrt && git checkout -- . && git clean -fdx -- target/linux/mediatek
   ```
   （`dl/` 与 ccache 不要删，那是时间成本所在）

## 5. 和 CI 的关系

- **CI 是发布口径**：`build.yml` 跑同一套脚本，产物进 Artifact / Release
- **本地是快速反馈**：同脚本、同分支、同 `.config`，先在本机把错误找出来再推 CI
- 两条路径都过 `scripts/verify-device.sh`（补丁 apply → DTS 结构 → filogic.mk → 02_network）

## 6. 国内网络下的源码包（dl/）盲区

`make download` 会把失败的包记成一行 `ERROR: package/… failed to build`（名字虽叫 build，实际是下载失败），
然后继续跑；等到编译阶段才真正炸。第一次本地构建就踩到 `libsodium`：

- `download.libsodium.org`：TLS 直接被掐（`unexpected eof while reading`）
- GitHub Releases 上的 tarball：容器内 404 / 代理 404
- **可用替代**：Buildroot 源码镜像，文件名与 sha256 与原站完全一致
  ```bash
  cd /build/openwrt/dl
  curl -fsSL -o libsodium-1.0.20.tar.gz https://sources.buildroot.net/libsodium/libsodium-1.0.20.tar.gz
  sha256sum libsodium-1.0.20.tar.gz   # ebb65ef6ca439333c2bb41a0c1990587288da07f6c7fd07cb3a18cc18d30ce19
  ```

判断方法：`grep -a 'ERROR: package/' build.log` 看下载阶段红了哪些包，
再把缺失的 tarball 放进 `dl/`（OpenWrt 只按文件名 + hash 校验，来源不限）。

> CI（ubuntu-latest）不受这个限制，所以**发布口径仍以 CI 产物为准**；
> 本地容器只用于快速反馈。

## 7. CI runner 的"环境漂移"（2026-11-11 实录）

同一天里，早上三次构建的第 4 步（安装编译依赖）都 ✅，下午连续三次 ❌，代码一字未改：

```
E: Unable to locate package build-essential
E: Unable to locate package clang / cmake / device-tree-compiler
E: Package 'intltool' has no installation candidate
```

连 `build-essential` 都"没有候选"，只可能是 **apt 源本身不可用**（不是包改名），根源是
`ubuntu-latest` 换了镜像。两条对策已固化进 `build.yml`：

1. **固定 runner**：`runs-on: ubuntu-24.04`（别让 GitHub 在你不知情时换环境）
2. **apt 源自动回退**：清空 lists → 依次试 *镜像自带* / `archive.ubuntu.com` / `azure.archive.ubuntu.com` /
   `mirrors.tuna.tsinghua.edu.cn`，每个源都用 `apt-cache policy build-essential | grep -E 'Candidate: [0-9]'`
   验证"真有候选"才用，并区分**必需**与**可选**依赖（后者缺失只告警）

判定口诀：

| 日志特征 | 结论 |
|---|---|
| `Unable to locate package build-essential`（包名是核心工具） | 源不可用 → 查镜像/回退 |
| `Package 'intltool' has no installation candidate`（冷门包） | 新发行版移除 → 归到可选组 |
| `Ign:` / `Err:` + `Could not resolve` | runner 出网问题，重跑即可 |

## 8. 固定 runner 之后仍然要注意

- `ubuntu-24.04` 也终会下线（GitHub 会提前公告），到时把 `runs-on` 换到下一个 LTS 并重跑一遍
  `🧪 配置闸门` 验证即可（10 分钟）
- 与设备无关的失败（第 4 步之前/之后的环境类报错）**不要**去改设备补丁或包清单——先证明"代码没问题"
