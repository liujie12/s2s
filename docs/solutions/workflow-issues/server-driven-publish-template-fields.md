---
title: 类目发布模板是服务端下发的字段契约：选项字段统一走 OptionField／分段 PlateField，必填标记变更只需后端发版
date: 2026-10-31
category: workflow-issues
module: publish-car-fields
problem_type: architecture_pattern
component: frontend
severity: medium
related_components: [publish, template]
applies_when:
  - 为某个类目模板新增或调整发布字段，尤其是 select 选项字段或车牌这类分段结构字段
  - 需要判断「必填/可选」标记变更时，前端 APK 是否必须重新出包
  - 模板 fields 结构或 required 标记变更，需要新增 Flyway 版本并 bump template_version
  - 本地兜底模板 lib/domain/publish_template.dart 需要与服务端下发的模板保持一致
  - 原型多轮收敛后才定字段形态，需要把 UI 帧、契约、前端组件与测试对齐到同一真源
tags: [publish-template, server-driven-schema, template-version, flyway-migration, option-field, plate-field, flutter-form, required-flag]
---

# 类目发布模板是服务端下发的字段契约：选项字段统一走 OptionField／分段 PlateField，必填标记变更只需后端发版

## Context

拼车类目（模板 301）原先只有一句自由文本「车型」（`V4__seed_template.sql:28`，`car_model`，「如：轩逸（白色）」）。这一行同时承载品牌、车身形式与颜色三件事：同一台车会出现「白色轩逸三厢」「轩逸 白」「日产轩逸」等发散写法，既无法按品牌聚合，也无法在详情页稳定展示。

本轮要把这一行拆成 **品牌 / 车型 / 颜色 / 车牌** 四行，并经历了一次完整的「原型 → 契约 → 前端 → 发版 → 真机核对」链路；落地后用户又裁定「必填项要求都去掉，后期根据需求再定」，于是同一条链路再走了一遍**只改契约、不改代码**的调整。两次调整暴露的共性问题是：**发布表单的字段形态、候选值与必填标记，全部来自服务端模板下发，前端只按 `type` 渲染** —— 把这条前提认清楚，才能正确回答「这次改动要不要重出 APK」「老帖会不会坏」「原型和代码谁是真源」。

## Guidance

### 一、先定「真源层级」，再动任何一处

一次字段变更会同时触及五处，必须先排定优先级，否则改完就对不上：

| 层级 | 载体 | 权威性 |
|---|---|---|
| ① 契约 | 服务端模板 `template.fields`（`src/main/resources/db/migration/V28__template_car_fields.sql:23-25`） | **运行时真源**，客户端以它为准 |
| ② 本地兜底 | `lib/domain/publish_template.dart`（301 条目 `:250-263`） | 服务端模板拉取失败/未到达时使用 |
| ③ 前端常量 | `lib/domain/car_options.dart` | 只承载「输入辅助」值（品牌 / 颜色 / 省份 / 字母） |
| ④ 控件 | `lib/features/publish/option_field.dart`、`plate_field.dart` | 只按 `type` + 字段键分流，不含业务口径 |
| ⑤ 设计稿 | `prototype-figma/car-brand-picker.html` | 沟通载体，随裁定更新，**不是**运行时真源 |

反例：先在控件里写死品牌列表，再回头补 `fields` —— 服务端模板一到，两套候选值立刻分叉。正确做法是候选值先落 ③（或直接进 ① 的 `options`），控件只负责渲染。

### 二、长尾值用「下拉 + 手填兜底」，且手填不回写选项表

品牌、颜色是长尾数据（品牌 43 条、颜色 5 条常用但仍会出现「香槟金」），做成封闭选项必然漏。做法：

- 候选值来自模板 `options`；面板最多占一屏的一小半（`option_field.dart:165-177`，`maxHeight: 240`），超出内部滚动；
- 允许手填的字段白名单集中在 `car_options.dart:122-123`（`allowsCustomOption`，仅品牌/颜色），面板底部才出现「没找到？手动输入」（`option_field.dart:178-204`）；
- 手填后值行**原地**变输入框，右侧留「返回列表」出口（`option_field.dart:254-303`），不新开页面、不切换字段语义；
- 手填值原样入库，**不回写选项表**；再点一次已选项即视为清空（`option_field.dart:309-313`）。

反例：把「车型」也开放手填 —— 车身形式本身可穷举（轿车 / SUV / MPV / 跑车 / 微面 / 皮卡 / 其他），开放手填只会重新引入「轿车 / 小轿车 / 三厢轿车」的发散。可穷举的字段用封闭 `options`，只有长尾字段才给手填出口。

### 三、分段输入拼成单值：存储 / 展示分离，半截值不当值

车牌在交互上是三段（省份简称 + 发牌机关字母 + 号码段），在产品语义上是**一个值**。因此：

- 存储形态 = 单键单值 `plate_no`，形如 `皖A12345`；拼接时**任一段为空即返回空串**（`car_options.dart:160-168`），避免「选了省没填号码」这种半截值进入 `template_values`；
- 展示形态 = 带间隔点的 `皖A·12345`，由 `formatPlate` 在展示层生成（`car_options.dart:199-205`），存储值不带点；识别不出三段（历史自由文本）时**原样返回**，不清洗；
- 详情页按字段键分流到该格式化函数（`post_detail_provider.dart:174-175`），不在控件层做展示拼装；
- 号码段只做字符集与长度清洗（字母数字、自动大写、`NfrPublishCarLimits.plateCodeMinLength/MaxLength`，`car_options.dart:139-153`），**不校验真伪**、不进日志与埋点（车牌属个人信息，与手机号同一条红线）。

反例：拆成 `plate_province` / `plate_letter` / `plate_code` 三键 —— 字符串值会出现半截态、详情页要多三行、完整性判定还要处理「三段齐才算填」。

### 四、必填/可选只在模板层改，判定代码零改动

用户要求「必填项都去掉」时，最容易的错误是去改 `blocker` 判定或前端校验。正确做法：只改模板 `required` 标记。

- 301 的 `car_brand` / `car_model` 由 `required: true` 改为 `false`，`template_version` 再 + 1（`V29__template_car_fields_optional.sql:18-21`）；本地兜底模板同步去掉两处 `required`（`publish_template.dart:250-263`）；
- 服务端完整度判定（`required_full`）按模板标记逐字段计算（`src/main/java/com/s2s/server/post/PostValidator.java:160-163`），客户端提交拦截同样只读 `field.required` 与非空（`lib/features/publish/publish_form_state.dart:284-296`），因此**代码零改动**即自动变松；
- `blocker` 仍是「非空即已填」，四项留空只影响完整度标签（🟢/🟡），不拦提交；
- 原三行（路线 / 出发时间 / 空座数）保持必填 —— 放开范围要显式声明，不能「顺手全放开」。

反例：在发布页加一个「车辆信息至少填一项」的前端校验 —— 这是新造口径，且与模板 `required` 形成两套真源。

### 五、已发版的迁移只能追加，不能回改（与既有纪律联动）

V28 上线执行后，任何字节改动都会改变 Flyway 校验和，导致应用起不来。所以「把必填改掉」不能去编辑 V28，只能新增 V29。这与 [已应用的 Flyway 版本化迁移是不可变历史](./applied-flyway-migration-is-immutable-historical-artifact.md) 同一纪律，本次是它在**模板种子字段 / 必填标志**上的实例（该文示例链此前只到数值口径）。

推论：一次字段方案尽量一轮定死；不可避免的后续调整，按「新增版本 + bump `template_version`」处理，每个版本只描述 delta。

### 六、模板驱动 UI 的验证路径：先判「要不要重出包」

改动落地后，用一条判据决定发版范围：

- **只改了模板 `fields` / `options` / `required`** → 服务端发版即可，客户端重开 App 就会拉到新契约（模板按 provider 存活期缓存，不会自动刷新）。**APK 不必重出**；
- **改了控件渲染、值格式化、字段键分流** → APK 必须重出；
- 本次两次调整正好各占一边：V28 + 控件属于后者（要重出包），V29 只改 `required` 属于前者（只重发后端）。

真机核对时注意历史数据干扰：老草稿里 `depart_time` 仍是自由文本（如 `Wor55kday 8:00`），新控件会显示为「未选择」，**不要用旧草稿判断新控件是否生效**，应新建草稿。核对顺序：字段是否齐全 → 面板能否展开 → 手填入口是否就地变输入框 → 车牌三段拼接 → 提交后详情页展示形态。

## Why This Matters

- **少改一处真源，就少一次分叉**：字段形态由服务端模板下发，前端只按 `type` 渲染，使「加一个字段」变成「改模板 + 加一条渲染分支」，而不是在每个页面各写一套。
- **必填是产品口径，不是代码逻辑**：把它放在模板里，产品改主意时是数据变更（可回滚、可灰度、无需出包）；写进代码就变成版本变更，还要面对「老版本客户端仍在跑」。
- **半截值一旦入库就无法回收**：车牌拼单值 + 任一段空即空串，把「不完整」挡在入口，比事后清洗便宜得多。
- **发版范围判错会白跑一轮**：把只需重发后端的变更当成要出包，会多一次签名、分发与真机回归；反之把控件变更当成纯数据变更，会让用户看到旧界面。

## When to Apply

- 给某个类目加 / 改发布字段（尤其 `select`、`multi_select` 与自定义结构字段）；
- 产品在「必填 vs 选填」上反复时；
- 需要在「重发后端」与「重出 APK」之间做发版决策时；
- 原型与实现出现不一致、需要判定谁向谁对齐时。

## Examples

一次完整走查（本轮真实过程）：

1. **原型收敛**：`prototype-figma/car-brand-picker.html` 从「品牌搜索页」方案走到「四行 + 全 select 改下拉」，共四版；每版把裁定写回帧、SPEC 与 REVIEW，并把原「待定项」升级为「已定」。稿中品牌条数一度写 60，落地时按 `car_options.dart:49-93` 的 43 条回改为 43 —— 稿与码同源，稿子也要跟着改。
2. **契约扩字段**：V28 把 301 的 4 项扩为 7 项（`V28__template_car_fields.sql:23-25`），`car_model` 由 text 改 select，`car_brand` / `car_color` / `plate_no` 新增，`template_version` +1。
3. **前端落地**：候选值进 `car_options.dart`；`publish_screen.dart:1265-1279` 的 `select` 分支全量改为 `OptionField`、车牌按 `plate_no` 走 `PlateField`（`plate_field.dart:84` 拼接、`:183` 长度、`:230` 省份/字母共用同一面板）。
4. **放开必填**：V29 仅把两个字段的 `required` 改 false（`V29__template_car_fields_optional.sql:18-21`），补一条模板测试与表单测试；服务端无代码改动。
5. **发版判据**：V28 + 控件 → 出包；V29 → 只重发后端。
6. **真机核对**：debug 包连 prod，重开 App 拉新模板；核对四行、面板展开、手填就地变输入框、车牌 `皖 A 12345` 拼接；详情页应显示 `皖A·12345`。

## Related

- [已应用的 Flyway 版本化迁移是不可变历史](./applied-flyway-migration-is-immutable-historical-artifact.md) —— 本文第五条纪律的母篇，本次补上「模板种子字段 / 必填标志」实例。
- [设计参数评审与门禁](../workflow-issues/design-parameter-review-and-gating.md) —— 同为「多轮评审如何收敛」的方法论，本文聚焦字段方案。
- 上游探索件：`docs/ideation/2026-10-30-publish-vehicle-form-ideation.html`（该件中的候选 6「attributes 值类型升级 / 模板版本快照」本期未采纳）。
