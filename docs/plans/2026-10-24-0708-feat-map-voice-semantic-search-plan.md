---
title: Map Voice Semantic Search - Plan
type: feat
date: 2026-10-24
topic: map-voice-semantic-search
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

## Goal Capsule

- **Objective:** 用户在首页地图上用一句话（语音或文字）表达需求，系统解析出供需方向、类目、半径、地点、价格，地图就地按半径收窄 Pin 并过滤掉不相关资源或需求，收窄可见、可撤销、可解释。
- **Means:** 可见的一次性搜索圈 + 按住地图说话 + 确定性词表短路（KTD5, KTD6）。
- **Authority:** docs/PRD.md（§2.9/§2.10/§6.4 搜索与地图口径）；docs/architecture/编码规范.md（红线）。
- **Stop conditions:** 任一隐私合规项（R14）未落地，或地图侧价格过滤破坏 P95≤300ms 覆盖索引查询，即停止上线。
- **Tail ownership:** 前端 map 域与 discovery 域、后端 map/search 域、数据迁移，均为本计划范围。

---

## Product Contract

### Summary

在首页地图上新增语义搜索：用户用一句话（支持语音）描述需求，系统解析出地点锚点、供需方向、类目（含合租/整租叶子）、半径、价格，地图就地按半径收窄并画出可见的一次性搜索圈；圈内计数、圈外提示、可撤销。语音识别是核心亮点。

### Problem Frame

搜索框现在只做标题/描述的字面 `LIKE`，地图接口 `/map/pins` 没有 keyword 参数；PRD §6.4.1 要求的「同义词映射命中分类子树」未实现。用户说「我在锦绣小区要租房，1公里内2000以内，要合租」时，系统既无法理解地点与价格，也无法让地图 Pin 随之收窄——搜索与地图完全脱节。

### Requirements

**语音入口与识别**

- R1. 用户可按住地图任意点说话，按压点即空间锚点；检测到键盘输入立即停麦。
- R2. 语音转写文本在说完后立即回显且可编辑，作为解析输入；转写失败不阻塞文字输入。
- R3. 麦克风权限被拒时给出跳系统设置的可操作指引。

**语义解析（确定性短路优先）**

- R4. 解析结果为一张固定槽位卡：供需方向、类目叶子、半径、地点锚点、价格、类目专属属性。
- R5. 半径、类目、供需、价格等封闭词汇走确定性词表短路：命中即不出网、不扣 AI 配额、同一句话结果确定。
- R6. 地点锚点由两类输入得出：语音/文字里的地名（高德正向 POI 解析）、长按地图指定点；两者都无时用当前定位。
- R7. 词表未命中的自由文本进入 AI 严格 Scope 兜底；兜底同样受严格 Scope 约束，越界留空并提示「没敢用」。

**地图收窄与搜索圈**

- R8. 解析出半径、价格、类目与类目专属属性后地图就地收窄：按半径画出可见的一次性搜索圈，圈内正常、圈外压暗，并按价格区间与白名单内专属属性过滤；圈不写入持久筛选。白名单外专属属性不做地图层过滤，仅回显。
- R9. 搜索圈显示圈内计数；圈外命中折叠成「圈外还有 N 条 · 放宽到 X」角标，可点撤销回到上一档。
- R10. 半径圈按解析出的真实米数绘制，查询走既有档位，客户端按真实米数精裁后上图。
- R11. 零结果时圈上给出显式改写入口（扩圈/换供需/放宽类目），不自动改动用户范围。

**回显与可反驳**

- R12. 解析出的每个条件渲染成可点可删的 chip；越界或未命中字段灰态显示「没敢用」，可手动绑定或丢弃。
- R13. 收窄完成后给一行回执：听懂什么（chips）+ 排除多少（同半径无语义基线计数）。

**隐私与合规（上线前置）**

- R14. 隐私门告知清单补齐麦克风、录音、AI 三项；隐私政策补齐原始音频留存与删除条款。

**性能**

- R15. 说话结束到第一个可感知结果（转写文本或粗结果）先出，精算结果到达后再替换；失败保留前段结果。

### Key Decisions

- 留在原地图、按半径收窄，不新增独立搜索页 (session-settled: user-directed — chosen over 跳转独立搜索页: 用户明确「留在原地图」)。
- 语音识别是核心亮点，不是附属输入 (session-settled: user-directed — chosen over 仅文字搜索: 用户原话「这是我们的核心亮点功能」)。
- 采用「可见搜索圈 + 按住地图说话 + 确定性词表」组合 (session-settled: user-directed — chosen over 单点方案: 用户在 ideation 后指定「按这个组合推进」)。Governs R1, R5, R8。
- 地点锚点 = 语音解析地名 + 长按指定 (session-settled: user-directed — chosen over 单一输入: 核心功能不删减，两种输入都做)。Governs R6。
- 确定性短路优先，AI 严格 Scope 兜底随后。Governs R5, R7。

### Scope Boundaries

- 不新增独立搜索页；搜索是「首页内搜索态」。
- 不做 70B 端到端解析（PRD 红清单）；AI 兜底最多是严格 Scope 的 API/3B 阶段。
- 不做 S2 动态蜂窝半径自动扩圈（PRD 已推迟 Batch2）；零结果只给显式改写入口。
- 不做多轮增量对话（无会话基线）；每次语音是一次完整查询。
- 不做向量语义召回。

### Acceptance Examples

- AE1. **Given** 用户说「我在锦绣小区要租房」，**When** 解析完成，**Then** 地图以锦绣小区为中心，收窄到租房类目，圈内只显示房屋类 Pin。
- AE2. **Given** 用户说「1公里内、2000以内、要合租」，**When** 解析完成，**Then** 命中合租叶子（主卧/次卧出租），价格 ≤2000 过滤，半径圈为 1km。
- AE3. **Given** 用户说「租房」，**When** 走词表短路，**Then** 同义词映射命中房屋›租房子树（整租/合租/单间），不出网。
- AE4. **Given** 解析后 0 条，**When** 圈上出现改写入口，**Then** 用户可扩圈/换供需/放宽类目，不出现空白地图。
- AE5. **Given** 语音把「合租」听成「合作」，**When** 该词越界，**Then** 以灰态 chip 显示「没敢用」，用户可删或手动绑定。

### Success Criteria

- 一句话（语音或文字）→ 地图收窄完成，用户全程不离开地图。
- 确定性词表命中路径不出网、不扣 AI 配额，同一句话结果确定。
- 收窄可见且可撤销，不出现「地图莫名其妙变空」。

### Dependencies / Assumptions

- 高德正向 POI 可用（AMAP_KEY 已预留，SecretsProperties 有逆地理/POI 预留）。
- 服务端按 500m 网格扩圈、不做 Haversine 裁剪；圈计数需按真实距离计算或明确标注近似。
- 词表冷启动需人工投入，方言/简称/错别字会持续产生长尾。

### Outstanding Questions

- **Deferred to Planning:** 词表三消费方中发布页/筛选面板的接线顺序。

### Sources / Research

- docs/PRD.md §2.9/§2.10（同义词/拼音）、§6.4.1（搜索口径）、§6.4.4（S2 蜂窝半径）。
- docs/architecture/编码规范.md（红线）。
- docs/ideation/2026-10-23-map-voice-semantic-search-ideation.html（方向收敛依据）。
- 代码事实：map_screen.dart 搜索框、discovery_providers.dart PinsQuery、MapService.java expandGridCells、AiParseService.java 严格 Scope、reverse_geocode.dart（仅逆地理）。
- 研究确认：无 SearchController、后端零高德 Web 服务调用、`selectPins` 覆盖索引 `idx_pins_cover` 不含 price、`category` 表无同义词列、`DiscoveryFilter` 仅四字段、地图无 Circle 覆盖物、`record`/`permission_handler` 可用。

---

## Planning Contract

### Key Technical Decisions

- KTD1. 解析接口新增 `SearchController`（`POST /search/resolve`），游客可访问；AI 语义兜底对游客与登录用户**统一走同一大模型**（不区分通道/模型），游客以「游客记账账号」承担配额与费用。复用 `AiController` 的 `@Idempotent` + `AuthContext.currentUserId` 模式。Governs R4, R7。
- KTD2. 正向 POI 由后端新建高德 Web 服务客户端（`place/text`），Key 用 `SecretsProperties.amapKey`（可选绑定）；未注入则跳过 POI、锚点回退当前定位。结果按「城市 + 地名」缓存。Governs R6。
- KTD3. 地图价格过滤：`/map/pins` 增可选 `price_min`/`price_max`，`selectPins` 与 `countPins` 同步追加价格条件；新增迁移把 `price` 纳入 `idx_pins_cover` 覆盖索引以维持 P95≤300ms。设价格上限时 `price IS NULL`（面议）默认排除并在回执说明。Governs R8, R10。
- KTD3b. 地图专属属性过滤：引入「可筛选专属属性」白名单（模板 `select` 型、值域有限的字段，如合租的 `room_type`/`gender`），为每个白名单字段建 STORED 生成列（`JSON_UNQUOTE(JSON_EXTRACT(template_values,'$.<key>'))`，复用 `completeness_level` 的既有模式）并建等价复合索引；`/map/pins` 增可选 `attr_key`/`attr_value`（可多组），`selectPins`/`countPins` 追加生成列条件（过滤落 DB 层，否则 LIMIT 截断漏 Pin）。白名单外专属属性不做地图层过滤。Governs R8。
- KTD4. 前端语义解析结果用独立临时状态 `SearchIntent`（一次性、可撤销），不写入 `DiscoveryFilter` 持久筛选。Governs R8, R12。
[root@iZ8vb0k2o5b7h4ioh31dk2Z ~]# read -rsp '粘贴高德 Web服务 Key: ' K; echo
粘贴高德 Web服务 Key: 
4d1bt@iZ8vb0k2o5b7h4ioh31dk2Z ~]# ploy/env/.env.prod1de512d2c2b56938eabee9de2a6e 
-bash: ploy/env/.env.prod1de512d2c2b56938eabee9de2a6e4d1b: 没有那个文件或目录
[root@iZ8vb0k2o5b7h4ioh31dk2Z ~]# 
- KTD5. 同义词表 `category_synonym`（term、pinyin、leaf_category_id、weight、enabled、version），种子覆盖 48 叶子名称 + 常用别称。Governs R5, R7。
- KTD6. ~~词表短路实现：同义词/拼音/类目名/半径档/价格正则分层匹配，命中即返回；未命中自由文本才进 AI 严格 Scope；两层结果合并时确定性层优先。~~
  **2026-10-25 用户裁定取代本条**：所有搜索请求都走 AI 主解析，仅语义解析缓存命中时跳过模型调用；确定性词表保留为高置信锚点与 AI 不可用时的降级兜底。Governs R5, R7。
- KTD7. 搜索语音转写统一走大模型 ASR（通义千问），游客与登录用户均可：登录用户走 `AudioRecorder` 录音（`NfrMedia.maxAudioSeconds` 护栏）→ `mediaUploadService.upload` 得 `voice_media_id` → `signAiReadAccess` 取签名 URL → `AiProvider.transcribe`；游客录音后 base64 随 `/search/resolve` 以 `voice_audio_base64` 传入，后端用游客记账账号直接 `transcribe`（音频不落 OSS、不建 media 记录、转写即弃）。两路转写文本并入同一解析管线。Governs R1, R2。
- KTD8. 搜索侧 AI 主解析用独立 scope：不复用发布四件套，System prompt 输出 {供需方向、类目叶子集、半径档、价格上下限、地点、类目专属属性}，Step4 逐字段逆向比对越界留空。游客与登录统一走此管线（同一大模型），游客以游客记账账号承担配额与费用。Governs R4, R7。
- KTD9. 搜索语音音频仅用于即时转写，转写成功后立即删除（OSS 不留存），隐私政策如实写明；不承诺「音频从未上传」。Governs R14。
- KTD10. 游客限流：前期不限制（`/search/resolve` 不加 `@RateLimit`）；上线后按 `RateLimitThresholds` 的 GUEST_DETAIL 档（设备 30/d + IP 100/d、超限码 42907）补限频。登录用户 AI 兜底走 `AiQuotaGate`（42901）与费用台账；游客 AI 兜底走游客记账账号（同一配额/台账口径，身份维度区分）。Governs R4。

### High-Level Technical Design

数据流：输入 → 解析 → 槽位卡 → 地图收窄。解析分两层（词表短路 + AI 兜底），地点锚点独立解析，价格与白名单内专属属性过滤落到地图查询。

```mermaid
flowchart TB
  A[语音/文字输入] --> B[SearchResolveService]
  B --> B1[确定性词表<br/>同义词/拼音/类目/半径/价格<br/>锚点 + 降级兜底]
  B --> B2[高德正向 POI<br/>place/text + inputtips]
  B --> B3[AI 主解析<br/>缓存未命中必调]
  B1 --> C[SearchResolveResult 槽位卡<br/>供需/类目/半径/锚点/价格]
  B2 --> C
  B3 --> C
  C --> D[前端 SearchIntent 临时状态]
  D --> E[/map/pins 价格过滤<br/>price_min/price_max]
  D --> F[搜索圈 + 收窄 + chip 回显]
```

### Assumptions

- 解析接口文字与语音路径均游客可访问（不限流）：游客语音走 base64 直传 + 游客记账账号、不落 OSS；登录用户语音走 `voice_media_id`。AI 兜底游客与登录统一走同一大模型，游客以游客记账账号承担配额与费用。
- `AMAP_KEY` 未注入时正向 POI 降级为「未识别地点」，不阻塞整条解析。
- 地图侧价格过滤以 `post.price`（元）为准，`price_unit` 归一为「元/月」「元总价」等由解析层决定、不落库。

---

## Implementation Units

### U1. 同义词表迁移与种子

- **Goal:** 建立 `category_synonym` 表与种子数据，供词表短路消费。
- **Requirements:** R5, R7
- **Dependencies:** 无
- **Files:**
  - src/main/resources/db/migration/V17__category_synonym.sql（新建）
- **Approach:** 表含 `term`、`pinyin`、`leaf_category_id`、`weight`、`enabled`、`version`；种子覆盖 48 个叶子名称及其常用别称（「租房」↔「出租」↔「合租」、「保洁」↔「家政」等），拼音列填首字母。
- **Test scenarios:**
  - 迁移在空库与 V1–V16 全量库上均可重放，校验和无误。
  - 种子数据中「租房」命中房屋›租房下 20101/20102/20103 三个叶子。
  - 种子数据中「保洁」命中对应家政叶子。
- **Verification:** 迁移应用成功，`category_synonym` 行数 > 0，且按 term 查询能返回预期叶子集。

### U2. 后端语义解析服务

- **Goal:** 实现 `SearchResolveService`：词表锚点 + POI + **AI 主解析（全量走 AI，缓存命中跳过）**，产出槽位卡。
- **Requirements:** R4, R5, R6, R7
- **Dependencies:** U1
- **Files:**
  - src/main/java/com/s2s/server/search/SearchResolveService.java（新建）
  - src/main/java/com/s2s/server/search/SearchIntentCache.java（新建）
  - src/main/java/com/s2s/server/search/dto/SearchResolveRequest.java（新建）
  - src/main/java/com/s2s/server/search/dto/SearchResolveResult.java（新建）
  - src/main/java/com/s2s/server/search/CategorySynonymMapper.java（新建）
  - src/main/resources/mapper/CategorySynonymMapper.xml（新建）
  - src/main/java/com/s2s/server/search/AmapPoiClient.java（新建）
  - src/main/java/com/s2s/server/common/constants/NfrSearch.java（新建）
  - src/test/java/com/s2s/server/search/SearchResolveServiceTest.java（新建）
- **Approach:**
  1. 归一化文本（trim、全半角、大小写、去标点）。
  2. 词表提取：同义词/拼音/类目名命中叶子集；半径词映射 `1/3/5/10/city`；供需意图词定 `resource/demand`；价格正则提取数字 + 单位。词表结果只作锚点。
  3. POI 解析：`AmapPoiClient` 调 `place/text` / `inputtips`，返回坐标或小区实体；未命中返回空。
  4. AI 主解析：先查 `SearchIntentCache`（文本 + 城市 + 提示词版本），未命中即调搜索侧独立 scope（KTD8），越界字段进 `unresolved_fields`；AI 结果覆盖词表槽位。
  5. 降级：AI 超时/不可用/输出不可解析 → 沿用词表结果并置 `degraded=true`，不阻断搜索。
- **Execution note:** 先写 `SearchResolveServiceTest` 覆盖「缓存未命中必调 AI」「缓存命中不调 AI」「AI 不可用降级词表」三条分界，再补实现。
- **Patterns to follow:** `AiParseService` 的严格 Scope 逐字段溯源与错误映射；`MapService` 的 `validateFiveElements` 参数校验风格。
- **Test scenarios:**
  - 词表命中「租房」→ 返回房屋›租房叶子集，且仍调用 AI（全量走 AI，`aiUsed=true`）。
  - 同一文本 + 城市第二次请求 → 缓存命中，不调用 AI。
  - 「1公里内、2000以内、要合租」→ 半径 1、价格上限 2000、类目命中合租叶子。
  - 自由文本「离地铁近点」→ AI 主解析，越界字段进 `unresolved_fields`。
  - POI 未注入 Key → POI 解析返回空、锚点回退、不抛异常。
  - 中文数字价格「两千」→ 归一为 2000。
  - AI 抛异常/输出不可解析 → 降级词表结果，`degraded=true`，请求不失败。
- **Verification:** 单测全绿，`SearchResolveResult` 各槽位可溯源（词表 / POI / AI 来源标记正确）。

### U3. 解析接口与契约

- **Goal:** 新增 `POST /search/resolve` 并更新 openapi。
- **Requirements:** R4
- **Dependencies:** U2
- **Files:**
  - src/main/java/com/s2s/server/search/SearchController.java（新建）
  - docs/api/openapi.yaml（修改，新增 `/search/resolve` 与请求/响应 schema）
- **Approach:** `SearchController` 文字与语音解析均游客可访问（词表短路 + POI + 大模型 ASR + AI 语义兜底），游客与登录统一走同一大模型（KTD7/KTD8），游客以游客记账账号承担配额与费用；前期游客不限流（KTD10）。响应为槽位卡 DTO，字段含供需/类目叶子集/半径档/锚点坐标/价格上下限/类目专属属性/`unresolved_fields`/`source`。
- **Patterns to follow:** `AiController.parse` 的 `@Idempotent` + `@Valid` 组织方式。
- **Test scenarios:**
  - `POST /search/resolve` 传文字「租房」→ 200 且返回类目叶子集。
  - 空输入 → 40001。
  - 未登录 + 自由文本 → AI 兜底走游客记账账号返回完整槽位卡，不报 40101。
  - 契约校验：openapi 中 `/search/resolve` 请求/响应 schema 与 DTO 字段一致。
- **Verification:** 接口可调通，openapi 契约通过 API contract gate。

### U4. 地图侧价格 + 专属属性过滤与索引

- **Goal:** `/map/pins` 支持价格区间与白名单内专属属性过滤，并维持覆盖索引查询。
- **Requirements:** R8, R10
- **Dependencies:** 无（独立于 U1–U3）
- **Files:**
  - src/main/resources/db/migration/V18__pins_price_index.sql（新建）
  - src/main/resources/db/migration/V19__pins_attr_generated_columns.sql（新建，白名单生成列 + 索引）
  - src/main/resources/mapper/MapPostMapper.xml（修改 `selectPins`）
  - src/main/java/com/s2s/server/map/MapService.java（修改 `getPins`）
  - src/main/java/com/s2s/server/map/MapController.java（修改 `/map/pins` 参数）
  - docs/api/openapi.yaml（修改 `/map/pins`）
  - lib/features/discovery/map_repository.dart（修改 `fetchPins`）
  - lib/features/discovery/discovery_providers.dart（修改 `PinsQuery`）
  - lib/core/cache/pin_cache_key.dart（修改缓存键，纳入价格与专属属性要素）
  - test/features/discovery/pin_cache_key_test.dart（修改）
- **Approach:**
  1. `V18` 把 `price` 纳入 `idx_pins_cover`（或建等价复合索引）。
  2. `V19` 为白名单内专属属性字段建 STORED 生成列（`JSON_UNQUOTE(JSON_EXTRACT(template_values,'$.<key>'))`，复用 `completeness_level` 模式）并建等价复合索引；白名单字段清单对齐 `template` 的 `select` 型字段，首期覆盖合租 `room_type`/`gender` 等高频字段。
  3. `selectPins` 与 `countPins` 同步增加可选 `price_min`/`price_max` 与 `attr_key`/`attr_value`（可多组）动态条件；`MapService.getPins` 透传，保证 total 与 pins 一致。
  4. `/map/pins` 增可选参数；`openapi` 同步。
  5. 前端 `PinsQuery` 增 `priceMin`/`priceMax` 与 `attrKey`/`attrValue`，缓存键扩为对应要素。
- **Execution note:** 加价格与生成列条件后，用 EXPLAIN 验证 `selectPins` 仍走覆盖索引（`Using where; Using index`），否则回退索引方案（生成列不入 `idx_pins_cover` 则需独立复合索引）。
- **Patterns to follow:** `MapPostMapper.xml` 现有覆盖索引注释纪律；`completeness_level` 生成列范式（V1）；`pin_cache_key.dart` 五要素键写法。
- **Test scenarios:**
  - `selectPins` 带 `price_max=2000` → 仅返回价格 ≤2000 的 Pin。
  - `selectPins` 带 `attr_key=room_type&attr_value=主卧` → 仅返回合租主卧 Pin。
  - 无过滤参数 → 行为与现状一致（全量）。
  - 缓存键：有/无价格与专属属性参数产不同键，参数一致则键一致。
  - EXPLAIN 显示带价格与生成列条件的查询仍 `Using where; Using index`（或等价复合索引命中）。
- **Verification:** 单测 + EXPLAIN 结论注释落到 XML；`/map/pins` 带价格/专属属性参数返回正确子集。

### U5. 前端 SearchIntent 状态与解析接线

- **Goal:** 前端新增 `SearchIntent` 临时状态对象，接 `/search/resolve`。
- **Requirements:** R4, R12
- **Dependencies:** U3
- **Files:**
  - lib/features/discovery/search_intent.dart（新建）
  - lib/features/discovery/search_repository.dart（新建）
  - lib/features/discovery/discovery_providers.dart（修改）
  - test/features/discovery/search_intent_test.dart（新建）
- **Approach:** `SearchIntent` 为不可变对象（供需/类目集/半径档/锚点坐标/价格上下限/类目专属属性/`unresolvedFields`/`source`），实现 `==`/`hashCode`；`SearchIntentNotifier` 独立于 `DiscoveryFilterNotifier`。`search_repository` 调 `/search/resolve`，读超时用 `NfrNetwork.aiParseReadTimeoutSec` 收紧档。线上 JSON 以 snake_case `unresolved_fields` 为 wire name，前端反序列化为 camelCase。
- **Patterns to follow:** `DiscoveryFilter` 不可变 + copyWith + `Notifier` 组织方式。
- **Test scenarios:**
  - 解析成功 → `SearchIntent` 状态填充，`unresolvedFields` 与 `source` 正确。
  - 解析失败 → 状态保留前值或清空，不抛到 UI。
  - `==`/`hashCode`：相同槽位卡相等，不同则不等。
  - 解析中状态可取消旧请求（防抖 300ms 内旧请求作废）。
- **Verification:** 单测覆盖状态迁移与请求取消。

### U6. 前端语音入口

- **Goal:** 地图页实现按住说话 + 转写回显 + 权限指引。
- **Requirements:** R1, R2, R3, R15
- **Dependencies:** U5
- **Files:**
  - lib/features/discovery/voice_search_sheet.dart（新建）
  - lib/features/map/map_screen.dart（修改，语音入口 + 长按锚点）
  - test/features/discovery/voice_search_sheet_test.dart（新建）
- **Approach:**
  1. 长按地图任意点弹出语音面板，按压点作为 `SearchIntent` 锚点候选。
  2. 复用 `AudioRecorder`（`record` 插件），说话结束即回显转写文本到搜索框（可编辑）。
  3. 检测到键盘输入立即停麦。
  4. 权限被拒时给跳系统设置的深链（用 `permission_handler` 的 `openAppSettings`）。
  5. 登录用户音频上传得 `voice_media_id` 随请求转写、转写后即删（KTD9）；游客音频 base64 直传 `voice_audio_base64`、不落 OSS、转写即弃。
- **Patterns to follow:** `_AiVoiceSheet` 的录音/上传交互；`NfrMedia.maxAudioSeconds` 护栏。
- **Test scenarios:**
  - 按住 → 说话 → 松开，转写文本回显到搜索框。
  - 长按点的坐标写入 `SearchIntent` 锚点。
  - 键盘输入触发停麦。
  - 权限被拒 → 展示跳设置指引，不进录音态。
  - 转写失败 → 保留可编辑文本框，不阻塞文字输入。
- **Verification:** widget 测试覆盖录音/停麦/权限三分支。

### U7. 前端搜索圈、收窄、chip 回显与隐私合规

- **Goal:** 地图上绘制搜索圈、按半径/价格/白名单内专属属性收窄、chip 回显与撤销，并补齐隐私合规。
- **Requirements:** R8, R9, R10, R11, R12, R13, R14
- **Dependencies:** U4, U5, U6
- **Files:**
  - lib/features/map/search_circle_overlay.dart（新建）
  - lib/features/map/map_screen.dart（修改，搜索圈 + 收窄 + chip + 撤销）
  - lib/features/privacy/privacy_gate_screen.dart（修改，补麦克风/录音/AI）
  - docs/legal/隐私政策（草稿）.md（修改，补原始音频留存与删除条款）
  - test/features/map/search_circle_test.dart（新建）
- **Approach:**
  1. `search_circle_overlay` 用高德 `Circle` 覆盖物画半径圈；圈内正常、圈外压暗（遮罩）。
  2. 解析出半径/价格/白名单内专属属性后，`PinsQuery` 带上价格与专属属性要素重拉，客户端按真实米数做 Haversine 精裁。
  3. 圈边显示「圈内 N 条」+「圈外还有 M 条 · 放宽到 X」，可撤销回到上一档。
  4. 解析槽位渲染成可点可删 chip，`unresolved_fields` 灰态「没敢用」。
  5. 隐私门与隐私政策补齐（R14 是上线前置）。
- **Patterns to follow:** `_PinsStatusChip` 与 `_zoomOutToShowAll` 的现有角标/缩放模式；`location_guide` 的权限指引文案。
- **Test scenarios:**
  - 解析出半径 1km + 价格 2000 + 合租主卧 → 圈绘出、Pin 收窄到圈内且价格 ≤2000 且命中主卧。
  - 圈外有命中 → 显示「圈外还有 N 条」，点撤销回上一档。
  - 零结果 → 显示改写入口（扩圈/换供需/放宽类目）。
  - `unresolved_fields` 渲染为灰态 chip，可删或手动绑定。
  - 收窄回执显示「听懂什么 + 排除多少」。
- **Verification:** widget + 集成测试覆盖收窄/撤销/零结果三分支；隐私文案由法务确认后合入。

---

## Verification Contract

- 前端：`flutter test`（覆盖 `search_intent_test.dart`、`voice_search_sheet_test.dart`、`search_circle_test.dart`、`pin_cache_key_test.dart`）。
- 后端：`mvn test`（覆盖 `SearchResolveServiceTest`）。
- 契约：`docs/api/openapi.yaml` 通过 API contract gate（`/search/resolve` 与 `/map/pins` 参数一致性）。
- 性能：`selectPins` 带价格与白名单生成列条件仍 `Using where; Using index`（EXPLAIN 结论注释写入 XML）。

---

## Definition of Done

- 全部 U1–U7 单元完成且单测/集成测试通过。
- R1–R15 均有对应实现与测试覆盖；AE1–AE5 均可复现通过。
- R14 隐私合规项（隐私门 + 隐私政策）落地，无「音频未保存」这类无法证实的承诺。
- 覆盖索引查询在价格与白名单内专属属性过滤后仍满足 P95≤300ms（EXPLAIN 证据留存）。
- 无残留实验代码、无硬编码字面量（阈值/TTL/超时只引用 `NfrXxx` / `NfrSearch` 常量）。

---

## Implementation Status (2026-10-24)

- **已完成（代码）**：U1 V17 同义词表与种子；U2 `SearchResolveService`（词表锚点 + POI + AI 主解析 + 语音双通道）；
  U3 `POST /search/resolve`（`@Idempotent(anonymous = true)`，游客可访问）与 openapi；
  U4 `/map/pins` 价格过滤 + V18 覆盖索引；U5 `SearchIntent` / `search_repository` / `PinsQuery` 价格要素与缓存键；
  U6 语音面板（长按地图取点 + 按住说话 + 权限指引 + 键盘停麦）；U7 搜索圈自绘 + 圈内精裁 + chip 回显/撤销 + 隐私门与政策补充。
- **范围调整（KTD3b 暂不落地）**：V4 模板种子只为 101/301/401/501 四个 L2 建了自定义模板，201 租房 L2 无模板
  （主卧/次卧/整租本身就是 20101/20102/20103 叶子），不存在可筛的 select 字段。为不存在的字段建生成列属过度设计，
  故本轮不做「类目专属属性生成列 + attr 过滤」，类目差异全部由叶子类目集合承载。
- **待补**：真机联调（ASR 耗时、POI Key 注入、搜索圈视觉）；EXPLAIN 复测（V18 应用后带 `price_max` 的 `selectPins`）。
- **追加（2026-10-24 用户裁定）**：地址/小区改为「实体归一」而非向量——
  V19 新增 `post.community_id/community_name` 与 `idx_pins_community`；
  `AmapPoiClient` 增加 `inputtips`（住宅区、城市 adcode 限制）与逆地理取 adcode；
  `CommunityResolver` 做归一化 + 包含/编辑距离打分，高置信自动采用、低置信回候选由用户点选；
  发布侧 best-effort 解析小区，搜索侧 `/search/resolve` 回 `community_id/community_name/community_candidates`，
  `/map/pins` 增 `community_id` 等值过滤；前端 chip 可删除、候选可点选、0 结果提示清除。
  **已知缺口**：存量帖子无 `community_id`，需一次性回填；未回填前只能命中新帖。
- **EXPLAIN 实测（2026-10-24，本地 MySQL 8.0.46，Flyway 已到 V19）**：
  `idx_pins_cover` 与 `idx_pins_community` 在 `FORCE INDEX` 下均为 `Using where; Using index`
  （filesort 来自 price 范围后的 `ORDER BY id`，候选 ≤500 可接受）；`countPins` 为纯 index-only。
  另修正：`community_id` 存在时不再拼 `grid_id` 条件（索引不含 grid_id，拼上去会回表），
  小区范围本就比网格更紧。
- **真实高德命中（2026-10-25，Web服务 Key 验证通过）**：口语「北城新徽苑」在合肥
  只返回 1 个候选「北城世纪城鑫徽苑」（长丰县）。它既不是包含关系、又差一个同音字
  （新/鑫）+ 缺「世纪城」，相似度落在 [0.4, 0.8) → **回候选让用户点选，不静默采用**，
  已固化为单测 `真实小区简称走候选确认而不是静默采用`。
- **回填入口已验证**：`--backfill.community=true` 启动 10.8s，本地库 0 帖故 `processed=0`；
  线上按下方「小区回填命令」分批执行。

### 口径变更（2026-10-25 用户裁定）：所有搜索请求走 AI，除非命中缓存

- **后端**：`SearchResolveService.resolve()` 改为 AI 主解析——词表先跑只作高置信锚点，AI 结果覆盖槽位；
  新增 `SearchIntentCache`（Redis，key = `AI_PARSE_CACHE_PREFIX` + 提示词版本 + 城市 adcode + 文本 SHA-256，
  TTL `AI_PARSE_CACHE_TTL_SECONDS`；Redis 故障按未命中处理，fail-open）；
  缓存未命中必调模型；AI 超时/不可用/输出不可解析 → `degraded=true` 并沿用词表结果，不阻断搜索。
- **常量**：`NfrSearch.AI_PARSE_CACHE_PREFIX` / `AI_PARSE_PROMPT_VERSION` / `AI_PARSE_CACHE_TTL_SECONDS`。
  **提示词或输出契约变更必须递增 `AI_PARSE_PROMPT_VERSION`**，否则旧缓存会串味。
- **契约**：`/search/resolve` 响应新增 `degraded:boolean`；`ai_used` 语义为「本次是否走了 AI（缓存命中也算）」。
- **前端**：`SearchIntent.degraded` 解析，回执条显示「AI 暂时不可用，已按关键词理解」。
- **成本**：全量走 AI 后每次未命中都产生一次模型调用与台账记账（游客走游客记账账号），
  缓存命中率直接决定费用；上线后需看 `sources` 与缓存命中率两个指标。

### 小区回填命令

**前置**：镜像必须已包含 `CommunityBackfillRunner`（即本次发版之后）；V19 迁移由常驻实例启动时应用。

**小批观察（200 条，独立一次性容器）**——不占常驻容器内存、不发布端口、不动数据面：

```bash
cd /mnt/s2s/deploy
sudo S2S_ENV=prod docker compose \
  -f docker-compose.yml \
  -f compose/docker-compose.prod.yml \
  --env-file env/.env.prod \
  run --rm --no-deps --name s2s-backfill-200 --entrypoint sh app \
  -c 'exec java -Xmx256m -XX:MaxMetaspaceSize=192m -Xss512k -Dfile.encoding=UTF-8 -jar /opt/s2s/app.jar --server.port=0 --s2s.scheduling.enabled=false --backfill.community=true --backfill.community.limit=200'
```

**全量**：同一条命令去掉 `--backfill.community.limit=200`。

**三个参数为什么必须这么写**：
- `--entrypoint sh` + 自己拼 `java` 命令：镜像 ENTRYPOINT 是 `sh -c "java $JAVA_OPTS -jar /opt/s2s/app.jar"`，
  直接追加参数会被 `sh` 当成 `$0`，Spring 收不到任何参数（静默按常驻模式启动）。
- `--s2s.scheduling.enabled=false`：短命进程也会装配完整上下文，不关就会与常驻实例并发跑 11 个
  `@Scheduled` 任务，违反「单实例、无分布式锁」前提（开关见 `TaskSchedulingConfig`）。
- `-Xmx256m`：一次性进程独立容器（prod override `mem_limit: 750m`），不挤占常驻 app 的 600m 堆。

**观察指标**：
- 日志 `小区回填进度：processed=…, updated=…, cursor=…`，结束行 `小区回填完成：processed=…, updated=…`；
- `updated/processed` 比例：接近 0 说明地址里没有小区名或高德 Key 在该环境失效（看 10009 等 infocode）；
- `docker ps` 确认 `s2s-app` 的 Up 时长没有被重置（即未被 cgroup OOM 杀掉）。

**幂等**：只处理 `community_id IS NULL`，UPDATE 也带 `IS NULL` 条件，可反复执行。
节流：`NfrSearch.BACKFILL_BATCH_SIZE` / `BACKFILL_DELAY_MILLIS` 控制高德 QPS；未回填的存量帖只能靠坐标半径命中。

### 线上验证记录（2026-10-25）

- **发版**：镜像 `s2s-app:20261025-201756`，`s2s-app` healthy；`flyway_schema_history` 中 V17/V18/V19 均 `success=1`；
  `post.community_id/community_name` 与 11 列覆盖索引 `idx_pins_community` 均已就位。
- **`/search/resolve` 实测**（游客 + `Idempotency-Key`）：
  `{"text":"北城新徽苑租房","current_lng":117.22,"current_lat":31.95}` →
  `ai_used=true`、`degraded=false`、`sources={category:ai, post_type:ai, radius:ai, anchor:poi}`、
  `anchor_name=北城世纪城鑫徽苑`、`community_candidates` 1 条、`community_id=null`。
  即 AI 主解析、高德 Key、小区候选确认三条链路线上均通。
- **回填实测**：`exit=0`（该进程只有 runner 会主动退出，故确认已执行），
  生产库 39 帖中仅 20 条有地址，且全为街道门牌（如「蜀山区长江西路 100 号」），不含小区名
  ⇒ `updated=0` 属正确结果；存量测试数据无可回填对象，真实用户帖由发布侧写入 `community_id`。

### 运维踩坑记录（2026-10-25）

- **`APP_VERSION` 与实际镜像 tag 不一致会静默改走现场构建**：`env/.env.prod` 写的是 `1.0.0`，
  而实际发布 tag 是时间戳。`compose run` 找不到 `s2s-app:1.0.0` 就落到 `build:` 分支，
  用宿主旧产物构建出一个只有 5 条迁移的镜像（启动日志 `latest available migration (5)`）。
  办法：`run` 时显式 `APP_VERSION=<实际tag>`（shell 变量优先于 `--env-file`），并建议把 env 里的值改成实际 tag 或删掉。
- **`/search/resolve` 必须带 UUIDv4 的 `Idempotency-Key`**：`@Idempotent` 拦截器对匿名接口同样校验，
  缺失直接 40001。前端 `HeaderInterceptor` 对 POST 自动注入，手工 curl 容易漏。
- **INFO 级日志看不到回填进度**：生产 console 只出 WARN，`/var/log/app` 里也没有回填行，
  判断是否执行过要看 `exit=0`（唯一退出路径是 runner）或直接查库 `community_id`。

