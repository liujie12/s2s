---
title: WSL2 内 Docker 拉取镜像时大层永久停滞：根因是 MTU，降到 1400 即修复
date: 2026-10-11
category: runtime-errors
module: dev-environment
problem_type: runtime_error
component: infrastructure
symptoms:
  - "docker pull eclipse-temurin:21-jre-alpine / redis:7.4-alpine 在最后 1–2 个「大层」永久停滞：长时间停在 Pulling fs layer / Waiting，150 秒以上零字节进展"
  - "同环境小镜像秒下（docker pull hello-world），小文件本体（约 10KB）也能秒下——呈「小文件通、大文件死」的识别特征"
  - "在已有 4 个公共镜像站基础上把阿里云专属加速器置 registry-mirrors 首位并重启 dockerd 后，已完成的层与加之前完全相同，仍卡同一层"
  - "反复重试拉取（已下载层缓存复用）仍卡在同一层"
root_cause: config_error
resolution_type: config_change
severity: high
framework_version: "WSL2 Ubuntu 22.04 (systemd=true) + Docker Engine in WSL (2026-10)"
tags: [docker, wsl2, mtu, networking, image-pull, container-registry, dev-environment]
---

# WSL2 内 Docker 拉取镜像时大层永久停滞：根因是 MTU，降到 1400 即修复

## Problem

本机开发环境（Windows 11 + WSL2 Ubuntu 22.04，Docker Engine 装在 WSL 内、宿主无 Docker Desktop）中，`docker pull` 拉取含较大层的镜像（如 `eclipse-temurin:21-jre-alpine`、`redis:7.4-alpine`）时，最后 1–2 个「大层」会**永久停滞**：长时间停在 `Pulling fs layer` / `Waiting`，150 秒以上零字节进展且不报错；而同环境拉取小镜像（`hello-world`）秒下。根因是 WSL2 的 `eth0` MTU 与上行路径不匹配，**不是镜像源问题**；修复是把 `eth0` MTU 由默认 1500 降到 1400，并固化进 `/etc/wsl.conf`。

> 本条的根因判断是**基于现象做出的推断**（本次会话未采集 tcpdump 级证据），但经修复前后对照验证，并有一项排除性对照（换镜像源无效）。仓库内实测登记见 `docs/progress/Batch1-进度记录.md:6245`。

## Symptoms

- **二分特征（本条最有迁移价值的判据）：小文件通、大文件死。**
  - `docker pull hello-world`（10KB 级）秒级完成；
  - `docker pull eclipse-temurin:21-jre-alpine` / `docker pull redis:7.4-alpine` 卡在最后 1–2 个几十 MB 的层上，长时间停在 `Pulling fs layer` / `Waiting`，**零字节进展、无任何错误输出**。
- 反复重试无效：已下载的层有缓存可复用，但**始终卡在同一层**。
- 换镜像源无效（详见下节）：把阿里云专属加速器置于 `registry-mirrors` 首位并重启 `dockerd` 后，**已完成的层与加之前完全相同、仍卡同一层**。
- 现象与「网络慢」有本质差异：不是缓慢推进，而是**完全冻结**，且不超时、不报错、不重连。

> 相关历史迹象可佐证同类形态在出包链上早已出现：`docs/progress/Batch1-进度记录.md:3506` 曾记录「`docker pull mysql:8.4` 卡在下载完成但不结束」，说明这类大层停摆在本机并非孤例。

## What Didn't Work

1. **换镜像源（且这是一次有价值的排除性对照，而非白费）**
   - 该机 `/etc/docker/daemon.json` 原有 4 个公共镜像站（`docker.1ms.run` / `docker.xuanyuan.me` / `hub.rat.dev` / `docker.m.daocloud.io`）。把阿里云专属加速器 `https://h7g3q7jo.mirror.aliyuncs.com` 置于 `registry-mirrors` **首位**，`sudo systemctl restart docker` 重启 `dockerd` 后重拉。
   - 结果：**已完成层与加之前完全相同、仍卡在同一层**。
   - **为何这是有价值的对照**：它把「镜像源」这个第二常见的嫌疑对象**干净地排除掉了**。如果只做「换源后仍失败」而不记录「失败点逐字节一致」，就容易把问题继续归咎于「源不好/源限速」。恰恰是「换源后卡点丝毫无变化」这个不变量，证明瓶颈在**传输路径本身**而非源的可用性 —— 这直接把排查方向从「换源」拨向了「网络栈」，才导向 MTU。
2. **反复重试**
   - 依赖已完成层的缓存复用重拉，仍卡在同一层。说明不是偶发的源抖动或瞬时丢包。
3. **此阶段还暴露一个判断错误（如实登记）**
   - 本轮一度把「本地 dev」径直当成「容器化 dev」，去配镜像加速器、改 WSL MTU，并把**项目自己的 `mysql8` 容器误判为其他项目的容器而停掉**。事后确认这条路径**本不需要任何镜像拉取**（本机早有实测可复现的直跑配方）。教训已写入 `docs/progress/Batch1-进度记录.md:6244`：遇到「本地 dev」应先查本机既有形态与既有配方，再决定路径。

## Solution

**根治：降低 WSL2 `eth0` 的 MTU 到 1400。**

Before（默认）：

```bash
ip link show eth0 | grep mtu        # mtu 1500
```

After（本次会话实测有效命令，执行后同一条拉取立即完成）：

```bash
sudo ip link set dev eth0 mtu 1400
ip link show eth0 | grep mtu        # mtu 1400
```

**固化（重启 WSL 后仍生效）**：写入 `/etc/wsl.conf`，与既有 `systemd=true` **同处一个 `[boot]` 段**（该文件原有内容即 `[boot]` + `systemd=true` —— 环境侧事实，取自 2026-10-11 本机会话的实测读取，不在本仓库内、亦未随本次提交入仓）。（注意：**一个文件只能有一个 `[boot]` 段**，须追加行而非新增段）：

```ini
[boot]
systemd=true
command = ip link set dev eth0 mtu 1400
```

生效方式：在 **Windows 侧**执行 `wsl --shutdown` 后重新进入 WSL；验证：

```bash
ip link show eth0 | grep mtu        # 期望输出 mtu 1400
```

> 取证来源：`docs/progress/Batch1-进度记录.md:6245`（2026-10-11 条目，B 类环境坑，实测非推断）。

## Why This Works

**根因（本次会话结论）**：WSL2 的 `eth0` 默认 MTU 为 1500，但宿主到上游之间的实际路径 MTU 更小（典型情况是承载 PPPoE/VPN/隧道等封装的链路）。路径中任何一跳都比「发送端宣称的 MTU」小，就会出现 **PMTU 黑洞**：

- 小请求（`hello-world` 这类握手、清单、几 KB 的小层）报文尺寸低于路径 MTU，正常转发，于是「小文件秒下」；
- 大流量（几十 MB 的镜像层）必然出现被填满到 1500 字节的 TCP 大包，这些包在路径上**被静默丢弃**；
- 由于 ICMP「需要分片」/ `Fragmentation Needed` 回报被路径中间设备吞掉（或未回传），发送端拿不到「请降低包大小」的信号，仍持续以 1500 字节重传 → **TCP 停滞在黑洞里反复重传同一批大包**，表现为「永久等待、零进展、不报错」。

把 `eth0` MTU 降到 1400，使本地发出的报文尺寸**低于路径真实 MTU**，大包不再被丢弃，传输随之恢复 —— 这正是「改 MTU 前卡死 / 改 MTU 后同一命令立即完成」的对照所印证的。之所以选 1400（而非恰好等于 1480 等）是留出封装开销的安全余量，属本次会话的经验取值，未做逐值验证。

> 注：本仓库部署手册 `deploy/docs/部署操作手册.md:1353-1369`（附录 D.2）对「镜像拉取」给出的另一条路线（用第三方镜像站前缀拉取再 `docker tag` 回原名）针对的是**生产服务器上 Docker Hub 不可达 / 加速器回源失败**的**源侧问题**，与本条「源可达但大层传不动」的**路径侧问题**是两类不同故障；该手册**尚未收录 WSL2 MTU 这条**（见 Prevention 的文档缺口说明）。

## Prevention

**1. 前置探针：装了/重启了 WSL 后，先跑一条「大镜像」拉取作为探测，不要等出事再查。**

```bash
# 探针：能拉下来大层，说明路径 MTU 正常；卡住则大概率是 MTU 问题
wsl docker pull eclipse-temurin:21-jre-alpine
```

先做一次「小 + 大」对照即可快速分层定位：

```bash
wsl docker pull hello-world                     # 通 → 网络栈基础可用
wsl docker pull eclipse-temurin:21-jre-alpine   # 卡 → 大层路径问题（优先怀疑 MTU）
```

**2. 固化检查（把 MTU 写进 `/etc/wsl.conf` 后，每次 `wsl --shutdown` 重进都验一遍）：**

```bash
ip link show eth0 | grep mtu        # 期望 mtu 1400
```

**3. 如何与「镜像源慢」区分开（判据表）：**

| 信号 | MTU / 路径问题（本条） | 镜像源问题（D.2 那类） |
|---|---|---|
| 小镜像（`hello-world`） | **秒下** | 通常也慢 / 也失败 |
| 大层 | **完全冻结，零进展、不报错、不超时** | 缓慢推进，或报 `EOF`/`TLS timeout`/`unexpected EOF` 等明确错误 |
| 换镜像源 | **卡点逐字节不变**（换了等于没换） | 换源后通常有改善或失败点改变 |
| 报错 | **无** | 有明确网络错误 |
| 判据 | **「小通大死 + 换源不变」= 查 MTU** | 「换源即变 / 有明确报错」= 查源 |

关键区分口诀：**换源后「卡在同一层」就不要再折腾源了，去查 MTU。**

**4. 文档缺口（下一位维护者请注意）：**

- `deploy/docs/部署操作手册.md`（附录 D.2 镜像拉取）**尚未收录 WSL2 MTU 这条**，当前只覆盖了「换镜像源前缀 + `docker tag`」的源侧处置；本机的 WSL2 大层卡死经验仅存在于 `docs/progress/Batch1-进度记录.md:6245` 的进度条目里，**未进入任何运维/环境前置手册**。
- `deploy/scripts/env-up.sh:106-107` 中已有的 WSL 相关注释只涉及「WSL/NTFS 挂载点无法表达 Unix 权限位（`stat` 恒 777）」，**未提及 MTU**。
- `说明文档.md:110` 仅把 `docs/progress/Batch1-进度记录.md` 列为分册索引，其正文没有 WSL MTU 细节。
- 因此，若要把本坑提升为「环境前置要求」，应在 `deploy/docs/部署操作手册.md` 增补一条 WSL2 环境前置（`/etc/wsl.conf` 固化 MTU + 探针命令），使下次重装/换机的人无需再翻进度记录。

**5. 关联遗留（与本坑同源、尚未闭合）：**

- `docs/progress/Batch1-进度记录.md:6247` 记录：**容器化 dev（`env-up.sh dev`）未验证**，当时「受镜像拉取所限，已放弃该路径」。MTU 修复后该路径理论上已解锁，可再验；「app 镜像 JRE 是否自带 `keytool`」亦仍未验。
- `docs/progress/Batch1-进度记录.md:3506` 记录：`docker pull mysql:8.4` 卡在下载完成但不结束、8.4 LTS 兼容性未验证 —— 属同类大层停摆的历史迹象，值得在 MTU 修复后一并复核。

## Related Issues

- [destructive-script-parameter-audit.md](../workflow-issues/destructive-script-parameter-audit.md) —— **前提关系**：该篇把「全程在 WSL 内执行 `docker`」当作既有执行前提；本条正是该前提成立所需的**环境底座**（MTU 未修复时镜像根本拉不下来）。同时该篇存在**覆盖不全**的轻度风险：它隐含「进 WSL 就能直调 docker」为无条件可靠，未提网络栈可能不可用。
- [review-findings-require-empirical-verification.md](../workflow-issues/review-findings-require-empirical-verification.md) —— **互补**：同属「WSL/容器开发环境的静默陷阱」主题（该篇举 drvfs 权限被转 777 一类），本条是其在**网络栈**层的实例；本条给出的「小文件秒下 vs 大层停滞」+「换源卡点不变」排除性对照方法可并入其「实测核验清单」。
- [verification-code-fails-silently-as-pass.md](../workflow-issues/verification-code-fails-silently-as-pass.md) —— **弱关联**：同属「静默失败难以归因」家族（本条停滞无报错、进度条不动），可作为「为什么要用对照实验逼出真相」的同族参照。
