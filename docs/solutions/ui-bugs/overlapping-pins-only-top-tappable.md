---
title: "同一位置的多条信息只露出最上层那枚 Pin：重合点只有最上面一条能被点中"
date: 2026-10-30
category: ui-bugs
module: discovery-map-markers
problem_type: ui_bug
component: frontend
symptoms:
  - "同一坐标发了 2 条信息，地图上只看到 1 枚 Pin，左下角计数却是「附近 2 条」"
  - "点这枚 Pin 永远命中同一条，另一条无论怎么点都打不开"
  - "两条落在同一点但类目不同时，连聚合圈都不出现，两枚 Pin 直接叠死"
root_cause: logic_error
resolution_type: code_fix
severity: high
related_components: [discovery, publish]
tags: [flutter, map-marker, clustering, overlap, hit-test, custom-paint, bottom-sheet]
---

# 同一位置的多条信息只露出最上层那枚 Pin：重合点只有最上面一条能被点中

## Problem

同一个用户在同一个位置发多条资源/需求是常态。旧实现把这些点画成多枚**完全重合**的 Pin，而命中判定是倒序遍历 Marker 列表、返回第一个命中的 —— 于是屏幕上永远只有最后画的那条能被点中，其余几条在交互上等同于不存在，用户也看不到「这一处其实有几条」。

## Symptoms

- 同一坐标两条信息 → 图上 1 枚 Pin，命中数却显示 2 条；点它只进得去同一条。
- 两条同类同点、且条数低于该大类阈值时，既不成聚合圈也不成单点切换，就是两枚叠死的 Pin。
- 两条**不同类目**同点：由于聚合分桶键含一级大类（[grid_cluster.dart:138](file:///d:/developer/code/aicoding/s2s/lib/features/map/clustering/grid_cluster.dart#L138)），它们连聚合圈都不会出现。

## What Didn't Work

- **调大类聚合阈值**。阈值只回答「几条算这一片很密」，2 条同类仍低于工作类的 3 条门槛，于是继续走「未达阈值拆回单点、各回原坐标」这条分支（[marker_builder.dart:176](file:///d:/developer/code/aicoding/s2s/lib/features/map/clustering/marker_builder.dart#L176)）—— 拆回原位正是重合的来源。
- **靠放大解决**。这些点坐标本来就相同，放大只是让重合的 Pin 变大，选不中还是选不中。
- **只放大命中半径**。倒序命中（[marker_layer.dart:75](file:///d:/developer/code/aicoding/s2s/lib/features/map/marker_layer.dart#L75)）会先返回列表末位那枚，半径再大也仍然是同一条，另外几条永远轮不到。
- **只按类目聚合**。分桶键带大类是聚合圈配色的前提，改掉它会退化成「五色混聚」，比原缺陷更难解释。

## Solution

在**网格聚合之前**插入一层「位置重合分组」，把同点的一组压成一枚带数量的 Marker（叠点堆），点它展开清单挑一条。

1. **纯 Dart 分组**（[grid_cluster.dart:173](file:///d:/developer/code/aicoding/s2s/lib/features/map/clustering/grid_cluster.dart#L173)）：以容差为格边长的空间哈希 + 3×3 邻格，与**组首点**比距离（用组中心会随成员增加漂移，导致同组内出现超容差成员）。只看位置，不看类目。

```dart
final List<List<ClusterPoint>> groups = groupOverlappingPoints(points, tolerance: stackTolerance);
```

2. **叠点堆 Marker + 流水线**（[marker_builder.dart:66](file:///d:/developer/code/aicoding/s2s/lib/features/map/clustering/marker_builder.dart#L66)、[:219](file:///d:/developer/code/aicoding/s2s/lib/features/map/clustering/marker_builder.dart#L219)）：组内 ≥2 条生成 `StackMarker`，主层取完整度最高者（同档按 ID 升序，保证两次渲染顺序一致），其余成员留在 `memberIds` 里给清单用；单点组照旧走原 `buildMarkers`。

```dart
return [...buildMarkers(rest, clusters, thresholdOf: thresholdOf), ...stacks];
```

3. **渲染与命中**（[marker_layer.dart:363](file:///d:/developer/code/aicoding/s2s/lib/features/map/marker_layer.dart#L363)、[:518](file:///d:/developer/code/aicoding/s2s/lib/features/map/marker_layer.dart#L518)）：主层 Pin + 右下 1–2 层「其它条分类色」叠影 + 右上深色数量角标（角标**替代**需求态的 `?`，同一位置只挂一个角标）；绘制顺序是「聚合圈 → 单点 → 叠点堆」，与倒序命中一致；命中半径按最远一层叠影外扩。

4. **清单与跳转**（[overlap_list_sheet.dart:35](file:///d:/developer/code/aicoding/s2s/lib/features/map/overlap_list_sheet.dart#L35)、[map_screen.dart:1538](file:///d:/developer/code/aicoding/s2s/lib/features/map/map_screen.dart#L1538)）：透明 barrier 的 modal sheet，点面板外的地图即收起；行内标题/价格按行 `postDetailProvider` 现取（`/map/pins` 紧凑格式不加字段），41001 行内降级「已下架」不可点。**点行直接 `push('/detail/{id}')`**（2026-10-30 用户裁定），选中态先写入，从详情返回时地图停在该条。

阈值与上限收进 `NfrOverlap`（[nfr_constants.dart:150](file:///d:/developer/code/aicoding/s2s/lib/nfr_constants.dart#L150)），业务代码不写字面量。

## Why This Works

缺陷的根源不是「Pin 画得不好」，而是**分组维度缺了一维**：网格 + 类目回答不了「屏幕坐标几乎相同」。加上位置这一维之后，重合点从「N 个争抢命中区的 Marker」变成一个「有 N 个成员的 Marker」—— 命中不再是谁压在上面的竞争，清单再把选择权交回用户。

顺序不能反：先聚合再补分组时，同点不同类已经被大类分桶拆散，拿不回来了；反过来先按位置分组没有信息损失，类目只在画叠影时用到。

## Prevention

- **用断言锁分组语义**：`test/map_overlap_test.dart` 钉死三条 —— 两条同类同点必须产出 1 个 `StackMarker`（旧实现是 2 个单点）、两条不同类目同点同样必须合并、未重合的门点仍走聚合圈（叠点堆不得吞掉聚合圈）。
- **把顺序写进注释**：分组在聚合之前是这条设计成立的前提，不是实现细节，注释里要写清「反过来会丢什么」。
- **真机验证先造数据**：这一功能在只有 1 条在架信息的库里**无法被观测**，也看不出缺陷。先在同一坐标造 2 条再宣称已验证；首次真机就卡在这里。
- **选中态与主层同源**：主层取完整度最高者，清单首行也必须是它，否则用户会觉得「点进去是另一条」。

## Related Issues

- 设计稿与规格：[overlapping-pins.html](file:///d:/developer/code/aicoding/s2s/prototype-figma/overlapping-pins.html)（含 SPEC 01–06 与三项评议）。
- 进度与真机结论：[说明文档.md](file:///d:/developer/code/aicoding/s2s/说明文档.md)。
- 同日收口：距离文案原本在列表页与地图信息卡各写一份，清单是第三个消费方，按 §1.1 上浮到 `lib/core/text/distance_label.dart`。
