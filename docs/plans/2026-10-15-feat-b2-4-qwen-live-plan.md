# B2-4 阶段① 收尾 · 通义千问真实接入（两步走）

> **立此文件缘由（2026-10-15）**：用户提出「配 key + 关 dry-run」时，核对代码发现**真实 HTTP 调用从未实现** —— 光拨开关会让 AI 解析全部返 `50301`。故本项**不是配置活，是开发活**，立独立任务书交**新会话**开工（B2-4 会话属性 = 🟢 独立）。
>
> **本文件 = 该任务唯一开工依据**，自包含，不必回读立此文件时的对话。

---

## 一、现状（代码事实，非推测）

| 事实 | 位置 |
| --- | --- |
| 非 dry-run 分支**直接抛异常**（真实 API 未接入） | `QwenAiProvider#generate`：`if (!dryRun) throw new IllegalStateException(...)` |
| 当初留给联调的 TODO 清单 | 同文件 `DRY_RUN_TODO` 常量（三条：读配置 / 多模态入参 / 超时与失败口径） |
| 配置侧**只有** `s2s.ai.dry-run` | `src/main/resources/application.yml`、`deploy/config/app/application-prod.yml`；`s2s.ai.api-key` / `s2s.ai.model` / `s2s.ai.endpoint` **均不存在** |
| `generate(scopeJson, systemPrompt)` **拿不到媒体** | 模式② 的音频根本没进作用域 ⇒ **只改 provider 不足以让模式② 走真** |
| 四模式其余部分已通 | 契约（PRD §2302 两端点）/ 配额 / 确认页 / 内容标识 / 首页入口 均已落地，且 2026-10-14 真机验证过链路 |

**结论：B2-4 阶段① 里「调真实已备案模型 API」这一块没做，其余都做了。**

## 二、目标与验收

**总目标**：`s2s.ai.dry-run=false` 后四模式产出**真实**猜测，且仍满足 PRD §5.10「严格 Scope 四步管线、幻觉率 ≈ 0」。

**分两步（用户 2026-10-15 裁定）**

- **Step 1 · 文本通道** —— 接通义千问 OpenAI 兼容接口，跑通「文本 → 四件套」。可独立验收（模式③ 一问一答、模式① 的文本部分）。
- **Step 2 · 多模态通道** —— 图片 / 音频经 **OSS 签名 URL** 入参（`qwen-omni`），让模式① 图、模式② 语音走真。

**每步的验收**：`mvn -o clean test` 全绿 + 真机跑一次 + 记录实际产出；**模式② 必须真人出声**验证识别质量（不能只看链路通）。

## 三、Step 1 任务清单

1. **先核实 API（禁凭记忆写）**：以阿里云百炼**官方文档**为准核对 —— 端点路径、鉴权头、请求体字段、响应结构、`model` 取值。**查不到就停下问，不猜。**
2. 配置项：新增 `s2s.ai.api-key`（**环境变量 `DASHSCOPE_API_KEY`**）/ `s2s.ai.model` / `s2s.ai.endpoint`。**两处模板都要同步**（易漏）：仓库根 **`.env.example`**（与 `application.yml` 的 `${}` 占位做**双向核对**，零差异）+ **`deploy/env/.env.<env>.example`**（部署侧）。**示例文件只放占位，绝不放真值**。
   - ⚠️ **生效方式与 yml 不同**（2026-10-15 踩过同类跟头）：`.env.<env>` 是**容器创建时**注入的 —— 改完 `docker restart s2s-app` **不生效**，必须**重建容器**（`docker compose ... up -d --no-deps app`）或走正常发版。而 `deploy/config/app/*.yml` 是**挂载**的，改完 `docker restart` 即可。别把两者搞混。
   - ⚠️ **追加变量前先确认 `.env` 末行有换行符**：末行无换行时 `echo >>` 会把新变量**并进上一行**（静默坏行）。本仓库 **2026-10-10 已踩过**，见 `deploy/scripts/build-mysql-ca-truststore.sh` 第 114–115 行注释。写入用「先 `sed -i '/^KEY=/d'` 删旧行、再 `printf 'KEY=%s\n'` 追加」的幂等写法。
3. 实现 HTTP 调用（替换 `if (!dryRun) throw ...` 分支）：超时按 `NfrAi.UPSTREAM_TIMEOUT_SECONDS`（**引用常量名，禁写死数字**）；失败 → `IllegalStateException` → `50301`（**不新增错误码**）。
4. 提示词按 PRD §5.10 的 Scope 约束构造：只允许从 U∪N∪P 集合里搬运，**禁编造**。
5. 测试：dry-run 分支回归 + 真分支（**HTTP 打桩，不打真网**）+ 超时 + 失败映射。
6. 真机/接口验收（**需 key**）。

## 四、Step 2 任务清单（Step 1 验收后再开）

1. **接口扩展（关键，别漏）**：把媒体信息传进 scope —— 现签名 `generate(scopeJson, systemPrompt)` 拿不到媒体。涉及 `AiParseService` 与 scope 结构；**动手前先确认对外契约不破**。
2. 图片 / 音频以 **OSS 签名 URL** 入参：需**只读、短时效的 GET 签名**——与上传用的 PUT 签名是两套，别复用。
3. 模式① 图 + 模式② 音频分别验收；模式② 需真人出声。

## 五、前置（用户侧）

| 项 | 说明 |
| --- | --- |
| **API Key** | 百炼控制台 **`https://bailian.console.aliyun.com/cn-beijing/model/settings/api-key`**（**右上角先选地域 = 华北2·北京**；官方明确「每个地域有独立的接入域名、API Key 和模型列表，**不能跨地域混用**」——与 OSS 那次杭州/北京同源的坑）。创建：归属账号 = 阿里云主账号、业务空间 = 默认、权限 = 全部 → 复制。**Key 无失效期**（长期凭证）。⚠️ **不要贴进任何对话或文档**：直接写服务器 `deploy/env/.env.prod`（不入库、600）与本机 `.env`。官方另明确「**勿在客户端代码（App/浏览器）中使用长期 Key**」—— 本项目仅服务端使用，符合。 |
| **环境变量名** | **`DASHSCOPE_API_KEY`**（官方口径，且 DashScope SDK 默认亦读它）；由 `application-prod.yml` 的 `s2s.ai.api-key: ${DASHSCOPE_API_KEY:}` 映射 |
| **Base URL** | `https://dashscope.aliyuncs.com/compatible-mode/v1`（**OpenAI 兼容**，与代码 `DRY_RUN_TODO` 的「OpenAI 兼容」一致） |
| **模型档位** | 待定（候选 `qwen-omni-turbo` 等）；**Step 1 只需文本档** |
| **备案复核** | ⚠️ **硬前置**：开工前到国家网信办公告 / 算法备案系统**复核该模型仍在册**（备案清单为动态，每 1–2 月新增一批） |
| **费用口径** | 真实调用按量计费（《技术栈选型说明》§8.2 估 10–30 元/月）；是否设日上限待定 |

> 以上 API Key 入口 / 变量名 / Base URL 三项**取自阿里云官方文档**（`help.aliyun.com/zh/model-studio/get-api-key`，页面更新时间 2026-10-10），非记忆。

## 六、红线（违反以缺陷论处）

- **凭证不入仓**：key 只走 `.env.*`（gitignored），**禁**写进 tracked 的 yml ——「白名单直写 yml」那套做法**不适用于凭证**。
- **不新增错误码**（唯一口径 PRD §12.5）；上游失败复用 `50301`。
- **阈值 / 超时只引用常量名**（`NfrAi.*` 等）。
- **日志禁出现用户文本明文**：`QwenAiProvider` 头注已写明 scope 含用户输入，故该类不写任何日志。
- **Scope 四步管线不可省**（PRD §5.10）。
- **AI 能力须落在 T5 Survivor D5.1 三色清单的绿名单内**（本条属绿名单：调已备案境内模型 API）。

## 七、会话属性

**🟢 独立** —— 建议新开会话开工：本任务自带全部依据，不依赖任何前序热数据。

## 八、出处

- 条目：`docs/plans/Batch2-启动清单.md` 的 **B2-4** 行（会话属性 🟢 独立）。
- 裁定：2026-10-12《技术栈选型说明》§8.3（阶段① = 调已备案境内大模型 API）；2026-10-13 模型选型 = 通义千问（阿里云百炼），备案号 `ZheJiang-TongYiQianWen-20230901`。
- 现状判定与「两步走」：2026-10-15 本轮裁定（用户「按这个方案来」）。
