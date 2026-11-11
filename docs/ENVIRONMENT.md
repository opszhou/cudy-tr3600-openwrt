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
