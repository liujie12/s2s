---
title: 评审结论的实测核验：不跑容器的配置审查会漏掉两个静默陷阱
date: 2026-09-07
category: workflow-issues
module: deploy
problem_type: workflow_issue
component: infrastructure
severity: medium
root_cause: missing_validation
resolution_type: workflow_improvement
applies_when:
  - 代码审查（code review）涉及容器化运行时配置（my.cnf、Dockerfile、compose 编排）
  - 审查者仅凭静态代码阅读做出判断，未在容器内实测
  - 审查结论包含"这个配置会报错"或"这个写法不生效"等断言
  - 配置文件的依赖关系涉及容器 entrypoint 行为、镜像自带工具链、或 YAML 解析器的引号处理
tags: [code-review, docker, mysql, config-validation, workflow-improvement, empirical-testing, silent-failure]
---

# 评审结论的实测核验：不跑容器的配置审查会漏掉两个静默陷阱

## Context

对一个部署交付物（IaC 代码 + 部署文档）做自评审时，识别出 16 项问题，分 P0–P3 四级。在进入修复阶段前，**逐项做了实测核验**——不是凭记忆或经验判断，而是用 docker 跑容器、用 bash 跑脚本、用 `--validate-config` 跑配置校验。结果发现：

- **3 项评审结论是误判**（推翻率 ~19%）
- **1 项修复建议过度**（原本建议 `apk add curl`，实测镜像自带 curl）
- 如果跳过核验直接按评审结论修复，会引入不必要的变化，甚至破坏原有功能

## Guidance

**评审结论必须经过实测核验后才能进入修复阶段。** 这不是"多一道工序"，而是防止两件事：

1. **误判被当作缺陷修复**——把正确代码改错
2. **修复建议脱离实际运行时环境**——让修复方案包含不必要的依赖

### 核验的四种手段

| 手段 | 覆盖场景 | 示例 |
|------|---------|------|
| **容器内运行** | 配置文件的语法校验、运行时行为 | `docker run --entrypoint mysqld mysql:8.4 --defaults-file=... --validate-config` |
| **镜像内工具检查** | 判断镜像自带工具链 | `docker run --rm eclipse-temurin:21-jre-alpine sh -c "command -v curl"` |
| **YAML 解析器行为** | 环境变量注入、引号处理 | 用 `env_file` 实验含引号值的变量是否被剥离 |
| **Docker Compose 配置展开** | 端口映射、卷挂载、网络配置 | `docker compose config` 展开验证 published 端口归属 |

### 实测推翻的 3 个误判（实证）

1. **LABEL 变量展开**：评审称 `LABEL version="${APP_VERSION:-latest}"` 会写入字面量 `latest`。实测确认——有 `ARG APP_VERSION` 声明时 LABEL 会正常展开，**缺 ARG 声明才是字面量的真正原因**。修复方案从"换写法"改为"加 ARG 声明"。

2. **env_file 引号保留**：评审称 `.env` 中 JSON 值的引号会被 `env_file` 保留，导致应用启动时解析失败。实测三种写法（无引号 / 双引号 / 单引号包裹 JSON）均正确解析，**引号不会被保留**。无需修改。

3. **Alpine 工具链**：评审称 `eclipse-temurin:21-jre-alpine` 不含 curl/wget，需 `apk add curl`。实测 `command -v curl` 输出 `/usr/bin/curl`——**镜像自带 curl，仅缺 wget**。修复从"加 apk add"简化为"healthcheck 改 curl"。

### 两个静默陷阱（配置审查中最容易漏掉的）

**陷阱 1：MySQL 8.4 已移除 `expire_logs_days`**

`mysqld --validate-config` 遇到 `expire_logs_days` 会报 `unknown variable` 并 abort，容器根本起不来。替代参数是 `binlog_expire_logs_seconds`。静态阅读 my.cnf 时，这个参数看起来是完全合法的——它确实在 MySQL 5.7/8.0 中存在了多年。只有实测才能发现。

**陷阱 2：world-writable 配置文件会被静默忽略**

mysqld 对权限为 777 的 `.cnf` 文件只打一行 Warning（`World-writable config file is ignored`），然后**完全不理这个文件**。这意味着所有配置（buffer pool、binlog 过期、字符集）都不生效，但 mysqld 仍然正常启动——没有 ERROR、没有退出码非零。

这个陷阱在以下场景特别容易触发：
- WSL 的 drvfs 挂载（Windows 文件系统权限自动转为 777）
- 通过 sftp/scp 复制配置文件（权限位被重置）
- 版本控制外的配置文件传递

## Why This Matters

一次自评审 16 项结论，实测推翻 3 项——~19% 的误判率意味着：**不经过实测的代码审查，有约五分之一的可能性把正确的代码判定为有缺陷**。如果评审者是外部人员或工具，这个比例可能更高。

按"疑似问题"直接修复的代价：
- 误判 ⑨（LABEL）：多改了 Dockerfile 写法，实际不需要
- 误判 ⑭（env_file）：多改了 `.env.example` 格式，实际不需要
- 误判 ⑧（apk add）：多加了 `apk add curl`，徒增构建时间和镜像体积

按"评审结论就是事实"去修复，三处误判全部变成了"无意义的改动"——代码没错，但被改了。更严重的是，如果评审者坚定地认为"这就是问题"，修复者没有质疑，这些改动就进了代码库，变成了一段"不知道为什么在这"的代码。

## When to Apply

- 任何涉及运行时配置文件的审查（my.cnf、redis.conf、Dockerfile、compose 编排）
- 任何依赖特定版本特性的行为断言（"MySQL 8.4 支持这个参数"需要实测确认）
- 任何关于镜像内容、工具链的判断（"Alpine 镜像不含 curl"需要实测）
- 任何关于 YAML 解析器行为、引号处理的结论（"env_file 会保留引号"需要实测）
- 评审结论与代码静态阅读的印象不一致时

## Examples

### 正确的核验流程

评审发现 `my.cnf` 使用 `expire_logs_days`：

1. **静态分析**：确认该参数在 MySQL 5.7/8.0 文档中存在
2. **实测**：`docker run --rm --entrypoint mysqld mysql:8.4 --defaults-file=/tmp/my.cnf --validate-config`
3. **结果**：`unknown variable 'expire_logs_days'` → **确认是问题**
4. **修复**：改为 `binlog_expire_logs_seconds = 259200`
5. **再验证**：重新执行 `--validate-config`，退出码 0

### 错误做法（跳过实测）

评审发现健康检查使用 `wget`：

1. **静态分析**：Alpine 镜像很小，肯定不含 curl 和 wget
2. **推断**：需要 `apk add curl`（约 2MB）
3. **修复**：在 Dockerfile 添加 `apk add curl`
4. **后果**：不必要地增加了镜像体积，且基础镜像的 curl 版本被覆盖

### 正确的做法

1. **实测**：`docker run --rm eclipse-temurin:21-jre-alpine sh -c "command -v curl"`
2. **结果**：`/usr/bin/curl` → 镜像自带 curl
3. **修复**：healthcheck 从 `wget` 改为 `curl -sf`，无需安装

## Related

- [跨文档引用与口径搬运的核验约定](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/cross-document-reference-verification.md)
- [设计阶段的验证越界](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/phase-boundary-verification-scaffolding.md)
- [注入凭证与作废凭证分属不同平台](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/credential-revocation-target-mismatch-from-ledger-summary.md) — 姊妹篇：同一纪律在「凭证作废对象核对」场景的实战，凭挂账摘要险些作废错 key。