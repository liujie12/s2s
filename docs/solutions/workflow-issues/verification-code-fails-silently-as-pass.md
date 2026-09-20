---
title: 校验代码自身失效时会输出 PASS 而非报错：三种沉默模式
date: 2026-09-07
last_updated: 2026-09-09
category: workflow-issues
module: deploy
problem_type: workflow_issue
component: infrastructure
severity: high
root_cause: missing_validation
resolution_type: workflow_improvement
applies_when:
  - 写门禁脚本、校验脚本、CI 检查脚本这类「自身产出判定结论」的代码
  - 检查逻辑写成 if 探测命令; then FAIL; else PASS 这种反向结构
  - 校验函数在命令替换 $( ) 里被调用，且外层脚本刻意不用 set -e
  - 用黑名单正则去匹配「不该出现的写法」，而不是用白名单核对「应有的取值」
  - 检查项引用的对象（镜像 tag、容器、文件）可能根本不存在
  - 把 CLI 的 flag 拼进「透传参数」变量，而未区分全局 flag 与子命令 flag
tags: [gate-check, false-negative, bash, set-e, command-substitution, docker-compose, verification-gate, silent-failure]
---

# 校验代码自身失效时会输出 PASS 而非报错：三种沉默模式

## Context

IaC 交付物审查阶段，对 `deploy/scripts/gate-check.sh`（G1~G11 十一项部署面安全门禁）与 `deploy/scripts/env-up.sh`（三套环境唯一启动入口）逐项做实测核验，共确认 8 项缺陷。其中最危险的三项有一个共同特征：

**它们不是「检查漏报了某个具体问题」，而是「检查这套机制本身失效了，但输出的仍是 PASS 或静默成功」。**

普通业务 bug 会以异常、报错、行为不符的方式暴露自己。校验代码的 bug 不会 —— 校验代码的产出就是「通过/不通过」这一个结论，当它自身出错时，最常见的落点恰好是「通过」。于是缺陷被自己的产物掩盖：门禁天天绿灯，实际什么都没查。

三项缺陷的具体形态：

| 沉默模式 | 现场表现 | 危害 |
|---|---|---|
| 检查对象不存在 → 落入 else → 伪 PASS | `docker history s2s-app:latest` exit=1，`grep -q` 同样非 0，`if` 不成立，直接打印 `[PASS] 镜像 history 中无 COPY .env 层` | 本机根本没有该镜像，这项密钥泄漏检查从未真正执行过 |
| 命令替换里的 `exit` 只终止子 shell | `bash gate-check.sh badenv` 退出码 **141**（SIGPIPE），`ENV_NAME` 为空串，G1~G11 全部基于空环境名继续跑 | 全部十一项判定结果无意义，但脚本仍逐项打印 PASS/FAIL |
| 全局 flag 被当作子命令 flag 透传 | `env-up.sh dev --profile tls` 报 `unknown flag: --profile` | 这一项是「响亮失败」，但它揭示同一族错误：参数拼错位置时，成功与失败取决于 CLI 实现，不能靠推断 |

前两项是本文核心。第三项列在此处是因为它与前两项共享同一个诱因 —— **写的时候只想了「正常路径」，没有想「这段代码自身出错时会输出什么」**。

## Guidance

### 1. 反向检查结构必须先证明检查对象存在

危险结构是 `if <探测命令>; then fail; else pass; fi`。这个结构隐含一个前提：探测命令的非 0 退出码只可能意味着「没找到不该有的东西」。而实际上非 0 还可能意味着「命令本身失败了」、「对象不存在」、「权限不足」。这三种情况全部落到 `else`，全部打印 PASS。

修正方式是把「对象存在性」提升为一个独立的三态判定 —— 存在则检查、不存在则明确 SKIP，绝不复用 PASS 分支。[gate-check.sh](file:///d:/developer/code/aicoding/s2s/deploy/scripts/gate-check.sh#L228-L254) 的现行形态（2026-09-09 refresh 时核对，已收敛为 gate-lib 的结构化 `skip()`/`pass()`/`fail()` 调用；下方快照保留修复当时的展开形态，三态机制未变）：

```bash
if command -v docker >/dev/null 2>&1; then
  # 优先用调用方指定的 tag，否则取最近构建的一个 s2s-app 镜像
  # ${APP_VERSION:-} 的 :- 不可省：本脚本用 set -u，直接引用未定义变量会报错退出
  G2_IMAGE="${APP_VERSION:-}"
  G2_IMAGE="${G2_IMAGE:+s2s-app:${G2_IMAGE}}"
  if [[ -z "${G2_IMAGE}" ]]; then
    G2_IMAGE=$(docker images 's2s-app' \
      --format '{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}' 2>/dev/null \
      | sort -k2 -r | head -1 | cut -f1)
  fi

  if [[ -z "${G2_IMAGE}" ]] || ! docker image inspect "${G2_IMAGE}" >/dev/null 2>&1; then
    skip "G2" "本机无 s2s-app 镜像，镜像层未检查（如需指定版本：APP_VERSION=<tag> bash $0 ${ENV_NAME}）"
  elif docker history "${G2_IMAGE}" 2>/dev/null | grep -q 'COPY.*\.env'; then
    fail "G2" "镜像 ${G2_IMAGE} 的 history 中发现 COPY .env 层"
  else
    pass "G2" "镜像 ${G2_IMAGE} 的 history 中无 COPY .env 层"
  fi
else
  skip "G2" "docker 未安装，镜像层未检查"
fi
```

原缺陷还有一个加重因素：镜像 tag 写死为 `s2s-app:latest`，而 `deploy.sh` 构建出的 tag 是时间戳形式（如 `s2s-app:20260907-1430`），**从不生成 `latest`**。也就是说这项检查在任何机器上都不可能命中，永久伪 PASS。

**SKIP 必须是一个与 PASS/FAIL 并列的第三态，而不是 PASS 的一种。** 门禁汇总里 SKIP 计数不为零本身就是需要被看见的信号。

### 2. 命令替换中的 `exit` 无法终止主脚本

`ENV_NAME="$(resolve_env "$1")"` 这个写法里，`resolve_env` 运行在子 shell 中，它的 `exit 1` 只终止那个子 shell。主脚本拿到一个空字符串，继续往下跑。

有 `set -e` 时这个坑会被兜住（赋值语句的退出码非 0 会终止脚本）。但**门禁脚本刻意不能用 `set -e`** —— 门禁的价值在于一次跑完 G1~G11 给出全景，用了 `-e` 会在第一个 FAIL 处直接退出、后面的项永远不被检查。

两个约束叠加，结论是调用点必须显式 `|| exit 1`。[gate-check.sh](file:///d:/developer/code/aicoding/s2s/deploy/scripts/gate-check.sh#L73-L98)：

```bash
# ⚠ 本函数在命令替换 $( ) 中被调用，其 exit 1 只能终止子 shell，无法终止主脚本。
#   而本脚本【刻意不用 set -e】—— 门禁必须把 G1~G11 全部跑完再汇总，
#   用了 -e 会在第一个 FAIL 处直接退出、后面的项永远不被检查。
#   因此调用点必须显式 `|| exit 1`，否则非法环境名会让 ENV_NAME 变成空串，
#   后续所有检查基于空环境名执行，结果全部无意义（曾实测到这个缺陷）。
ENV_NAME="$(resolve_env "${1:-}")" || exit 1
```

注释里必须写明「为什么不用 `set -e`」。否则下一个人看到 `|| exit 1` 会觉得冗余（"加个 set -e 不就都解决了"），一改就把门禁的全景语义破坏掉。

### 3. 黑名单正则换成白名单核对

同一轮里另一项缺陷：G1b 检查「数据面端口是否只绑 loopback」，原实现是拿正则去原始 yml 里找 `0.0.0.0` 或找「省略了 host_ip 的写法」。实测 `- "192.168.1.5:3306:3306"` 这类绑到具体外网卡的写法被完全漏检。

黑名单的问题是它要求穷举所有错误形态，而错误形态是开放集合。白名单只需定义唯一正确形态：展开后每个 published 端口的 `host_ip` 必须**恰为** `127.0.0.1`，其余一律 FAIL。

正确形态要从**展开后的结构**取，不是原始 yml。`docker compose config` 展开后 ports 的真实形态是：

```yaml
ports:
  - mode: ingress
    host_ip: 127.0.0.1
    target: 3306
    published: "3306"
    protocol: tcp
```

注意 `- ` 前缀出现在该项的**首个键**（这里是 `mode:`）上，`host_ip` 行**不带** `- `。这个细节在修复过程中直接坑了一次 —— 首版 awk 写成 `/^ *- host_ip:/`，导致 dev 环境明明全绑 `127.0.0.1` 却误报三次 `host_ip=(未设置)`。[gate-check.sh](file:///d:/developer/code/aicoding/s2s/deploy/scripts/gate-check.sh#L193-L201) 的最终判据：

```bash
BAD_BIND=$(echo "${COMPOSE_CONFIG}" | awk '
  /^[[:space:]]*(-[[:space:]]+)?host_ip:[[:space:]]/ { ip = $NF; next }
  /^[[:space:]]*(-[[:space:]]+)?published:[[:space:]]/ {
    port = $NF
    gsub(/"/, "", port)
    if (ip != "127.0.0.1") printf "  published=%s host_ip=%s\n", port, (ip == "" ? "(未设置)" : ip)
    ip = ""
  }
')
```

### 4. 校验代码必须做负向实测

上述任一项都无法靠阅读发现 —— 三处代码单看都「像是对的」。唯一有效的手段是**构造应当 FAIL 的输入，确认它真的 FAIL**：

| 检查项 | 正向实测 | 负向实测 |
|---|---|---|
| G1b 端口绑定 | dev 全绑 127.0.0.1 → PASS | 改成 `0.0.0.0:3306:3306` → FAIL；改成 `192.168.1.5:3306:3306` → FAIL |
| resolve_env | `gate-check.sh dev` → 正常跑完 | `gate-check.sh badenv` → 退出码 1；无参 → 退出码 1 |
| G2 镜像层 | 有镜像时命中检查 | 无镜像 → `[SKIP]` 而非 `[PASS]` |
| `--profile` 透传 | `--profile tls` → `[INFO] 已激活 compose profile：tls` | `--profile` 缺参数 → 明确报错 |

负向实测意味着要临时改配置、临时造非法输入。为此每轮实测都走临时脚本（`deploy/_tmp_*.sh`），跑完即删，配置改动当场还原，最后用 `git status --short deploy/` 确认无残留。

### 5. CLI flag 的位置属于必须实测的知识

`--profile` 是 `docker compose` 的**全局 flag**，只能出现在子命令**之前**。而脚本原本把它拼进 `EXTRA_ARGS`，也就是拼在子命令之后 —— `docker compose up -d --wait --profile tls` 直接报 `unknown flag: --profile`。

修复不是「换个位置拼」（那样要为每个子命令分别处理），而是转译为 `COMPOSE_PROFILES` 环境变量，它对 `config` / `up` / `down` 所有子命令一致生效，从此不用关心参数位置。[env-up.sh](file:///d:/developer/code/aicoding/s2s/deploy/scripts/env-up.sh#L63-L93)：

```bash
# 说明：--profile 必须在此单独拦截，不能混进 EXTRA_ARGS 透传。理由：
#       --profile 是 docker compose 的【全局 flag】，只能出现在子命令之前
#       （docker compose --profile tls up），而 EXTRA_ARGS 是拼在子命令之后的
#       （docker compose up -d --wait --profile tls），后者会直接报
#       "unknown flag: --profile" 而失败。故转译为 COMPOSE_PROFILES 环境变量，
#       它对 config / up / down 所有子命令一致生效，无需关心参数位置。
  --profile)
    [[ $# -ge 2 ]] || die "--profile 后必须跟 profile 名，如：--profile tls"
    COMPOSE_PROFILES="${COMPOSE_PROFILES:+${COMPOSE_PROFILES},}$2"
    shift 2 ;;
  --profile=*)
    COMPOSE_PROFILES="${COMPOSE_PROFILES:+${COMPOSE_PROFILES},}${1#--profile=}"
    shift ;;
```

配套的一个反直觉点：`COMPOSE_PROFILES` **不能无条件 export 空值** —— 空字符串会被 compose 当作「显式指定了空 profile 集」，反而干扰默认行为。故 [env-up.sh](file:///d:/developer/code/aicoding/s2s/deploy/scripts/env-up.sh#L172-L178) 只在用户确实传了 `--profile` 时才 export。

## Why This Matters

一个失效的门禁比没有门禁更糟。没有门禁时，团队知道自己没有这层防护，会用别的方式（人工 review、上线前 checklist）补。而失效的门禁提供的是**虚假的安全感**：每次上线前看到一片绿灯，于是跳过了本来会做的人工核对。

本次三项缺陷的实际暴露面：

- G2 伪 PASS —— 密钥文件被 `COPY` 进镜像层这类「镜像一旦推到仓库就是永久泄漏」的问题，在门禁上永远显示已检查通过
- resolve_env 不终止 —— 传错环境名（`prd` 打成 `prod`、CI 里变量没展开）时，门禁对着空环境名跑完十一项并给出汇总，人看到的是一份格式完整、内容全假的报告
- G1b 漏检 —— MySQL 3306 绑到内网卡后，同网段任意主机可直连数据库，而门禁报「端口绑定合规」

三者的共性放大了危害：**它们都不会随时间自愈，也不会被后续正常使用触发**。只有专门去做负向实测才能发现。

这也是本仓库同一天另一篇学习 [评审结论的实测核验](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/review-findings-require-empirical-verification.md) 的进一步收窄：那篇讲「评审结论不能靠推断，要跑起来验」；本篇讲的是「**验的那段代码本身也要被验**」—— 递归的最后一层，恰好最容易被跳过，因为它的产出形式就是「通过」。

## When to Apply

- 写任何形态的门禁 / 校验 / 断言脚本时，先问「这段代码自己出错会输出什么」
- 看到 `if <cmd>; then fail; else pass; fi` 结构时，检查 `<cmd>` 非 0 的所有可能成因
- 看到 `VAR="$(func ...)"` 且 func 内含 `exit` 时，确认外层是否有 `set -e`，无则补 `|| exit 1`
- 用正则做「禁止某种写法」的检查时，考虑能否改成「必须是某个取值」的白名单
- 检查项引用外部对象（镜像、容器、文件、服务）时，为「对象不存在」单独准备 SKIP 分支
- 把参数拼进透传变量前，确认该 flag 是全局 flag 还是子命令 flag

## Examples

**反向检查结构 —— before / after：**

```bash
# before：镜像不存在时 docker history 非 0 → grep 非 0 → if 不成立 → 打印 PASS
if docker history s2s-app:latest | grep -q 'COPY.*\.env'; then
  fail "镜像 history 中发现 COPY .env 层"
else
  pass "镜像 history 中无 COPY .env 层"   # ← 镜像根本不存在时也走这里
fi

# after：存在性判定独立成一态
if [[ -z "${G2_IMAGE}" ]] || ! docker image inspect "${G2_IMAGE}" >/dev/null 2>&1; then
  echo "  [SKIP] 本机无 s2s-app 镜像，跳过镜像层检查"
elif docker history "${G2_IMAGE}" 2>/dev/null | grep -q 'COPY.*\.env'; then
  fail "镜像 ${G2_IMAGE} 的 history 中发现 COPY .env 层"
else
  pass "镜像 ${G2_IMAGE} 的 history 中无 COPY .env 层"
fi
```

**命令替换里的 exit —— 最小复现：**

```bash
#!/usr/bin/env bash
# 注意：无 set -e
f() { echo "[ERROR] bad input" >&2; exit 1; }
V="$(f)"
echo "到这里了，V=[${V}]"   # ← 照常打印，V 是空串
```

实跑输出：

```
[ERROR] bad input
到这里了，V=[]
```

加 `|| exit 1` 后：

```bash
V="$(f)" || exit 1
echo "不会执行到这里"
```

**负向实测的组织方式** —— 临时脚本跑完即删，配置改动当场还原：

```bash
# deploy/_tmp_verify.sh（本轮结束即 DeleteFile）
# 1. 备份 override → 2. 注入非法端口 → 3. 跑门禁断言 FAIL → 4. 还原 → 5. 复查 git status
```

## Related

- [评审结论的实测核验：不跑容器的配置审查会漏掉两个静默陷阱](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/review-findings-require-empirical-verification.md) —— 同一原则的上一层（评审结论要实测），本篇是「校验代码自身也要被实测」这一层。两篇同属 deploy / infrastructure，建议后续 refresh 时评估是否合并为一篇「验证链的每一环都要闭环」
- [破坏性脚本的传参审计：参数就是写入授权](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/destructive-script-parameter-audit.md) —— 同为「脚本参数处理」类风险，那篇管写入授权，本篇管参数位置与校验失效
- [设计阶段的验证越界](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/phase-boundary-verification-scaffolding.md) —— 同为「为验证而搭的工程」的边界问题
- 落地记录：[说明文档.md](file:///d:/developer/code/aicoding/s2s/说明文档.md) 条目 [106]（IaC 四类交付物 + 本轮 8 项审查修复）
- [fail-closed 质量守门：判据工程化、变异自检与合并态活体实证](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/fail-closed-gate-judgments-with-mutation-self-checks.md) —— fail-closed 原则在 Dart 守门测试侧的镜像落地：「不可读/缺失文件即 FAIL」「inspected>0 空扫描面守卫」是本文 SKIP≠PASS 的工程化形态
