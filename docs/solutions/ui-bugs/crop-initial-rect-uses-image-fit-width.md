---
title: "crop_your_image 默认初始裁剪框按图片适配宽度计算：竖图仅占约 71% 屏宽"
date: 2026-10-19
category: ui-bugs
module: publish-media-crop
problem_type: ui_bug
component: frontend
symptoms:
  - "竖图进入裁剪页时，裁剪框只占屏宽约 70%，左右两侧残留大片黑色蒙版"
  - "图片随后被放大铺满视口，裁剪框明显窄于可见图片，看起来像「只能裁中间一条」"
  - "裁剪框宽高比虽为目标 1.803，但可用区域被浪费，用户需反复缩放图片才能框住主体"
root_cause: wrong_api
resolution_type: code_fix
severity: medium
framework_version: "flutter (dart sdk 3.11.5) + crop_your_image 2.0.1"
related_components: [publish, media]
tags: [flutter, crop-your-image, crop-rect, viewport, third-party-default, ui-geometry, publish-media]
---

# crop_your_image 默认初始裁剪框按图片适配宽度计算：竖图仅占约 71% 屏宽

## Problem

发布页的可选裁剪功能在竖图上打开时，`crop_your_image` 2.0.1 的默认初始裁剪框按「图片按高度适配后的宽度」（`imageRect.width`）计算，而不是按裁剪组件的视口宽度；交互模式随后又把图片 `scaleToCover` 放大到铺满屏宽，但框坐标不重算，于是框只占屏宽约 71%。修法是新增纯函数 `initialCropRect`，按视口四周内缩 8dp 取最大等比矩形。

## Symptoms

| 观测项 | 修复前 | 修复后 |
|---|---|---|
| 1080px 宽真机截图里的框宽 | 约 770px（71.3%） | **1036px（95.9%）** |
| 框高 / 宽高比 | 比例本身正确 | 574px / **1.805** |
| 视觉 | 框两侧大片图片露在遮罩外，像「没用上宽度」 | 框几乎铺满可用区域，仅留角点安全边距 |

- **只在竖图源上明显**。图片比例小于视口比例时走 `VerticalCalculator`，其 `imageRect` 是「按高度适配」的居中矩形，可能窄于视口；横图源的 `imageRect` 宽度通常已接近或等于视口宽，看起来「差不多正常」。
- **裁剪产物看不出问题**。产物始终按裁剪框与图片的映射关系切出，比例一直是对的；缺陷在进入页面那一刻的框几何，回看结果图无法发现。
- 详情页媒体卡口径没有变：宽 = 屏宽 − 2 × `AppSpacing.lg`，高 200，比例约 1.803，见 [media_display_layout.dart:17-29](file:///d:/developer/code/aicoding/s2s/lib/features/media/media_display_layout.dart#L17-L29) 与 [media_carousel.dart:90-95](file:///d:/developer/code/aicoding/s2s/lib/features/detail/media_carousel.dart#L90-L95)。裁剪框要贴近的正是这个比例。`1.803` 不是常量，而是本次设备（约 392.6dp 屏宽）下的推导值；比例真源始终是 `detailMediaAspectRatio()`。

## What Didn't Work

- **假设宽高比算错了**。`detailMediaAspectRatio()` 一行没改，修复前后都返回约 1.803；真机最终裁剪比例量得 1.805。比例口径从一开始就是对的，错的只是「框在视口里占多大」。
- **只对比裁剪输出**。输出会按 `cropRect` 与缩放后的 `imageRect` 换算后切图，比例正确、内容完整，因此产物侧完全看不到这个缺陷。必须看**进入裁剪页时的初始框**，而不是结果图。
- **信任库的默认初始框**。默认分支是 `_resizeWithSizeAndRatio(null, widget.aspectRatio)`，见 [crop.dart:481-482](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/crop.dart#L481-L482)，它最终走到 [crop_editor_view_state.dart:123-136](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/crop_editor_view_state.dart#L123-L136) 的 `cropRectInitialized`。竖图分支里框宽取的是 `imageRect.width * sizeRatio`，见 [calculator.dart:335-339](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/calculator.dart#L335-L339)。默认值「按比例、居中」看起来合理，但它的坐标系锚在图片适配框，不在视口。
- **只用横图验证**。横图源的 `imageRect` 宽度与视口宽接近，默认框和修复后的框几乎一样，缺陷被掩盖；必须用**比例明显小于屏幕比例的细长竖图**（如 1:3 长截图）才能复现约 71% 的现象。常见的 9:16 竖图在常规手机上比例仍大于屏幕比例，会走横图分支，框接近满宽，反而看不出问题。

## Solution

入口在发布页媒体段：点缩略图进入裁剪页，并把详情页比例传下去，见 [media_section.dart:169-177](file:///d:/developer/code/aicoding/s2s/lib/features/publish/media_section.dart#L169-L177)。裁剪页只接收 `aspectRatio` 参数，见 [image_crop_screen.dart:27-37](file:///d:/developer/code/aicoding/s2s/lib/features/media/image_crop_screen.dart#L27-L37)，自身不重复算比例。

### 修改前：不传 `initialRectBuilder`，走库默认

```dart
Crop(
  image: widget.source.bytes,
  controller: _controller,
  aspectRatio: widget.aspectRatio,
  interactive: true,
  fixCropRect: true,
  // 没有 initialRectBuilder：初始框由库按 imageRect 计算
  maskColor: Colors.black54,
  baseColor: Colors.black,
  ...
)
```

### 修改后：按视口算初始框

见 [image_crop_screen.dart:140-155](file:///d:/developer/code/aicoding/s2s/lib/features/media/image_crop_screen.dart#L140-L155)：

```dart
Crop(
  image: widget.source.bytes,
  controller: _controller,
  aspectRatio: widget.aspectRatio,
  interactive: true,
  // 锁定裁剪框、让用户拖动/缩放图片：比「拖框选区域」更符合
  // 手机上的单指操作习惯，也不会裁出比例不符的结果。
  fixCropRect: true,
  // 默认初始框只按「图片适配后的宽度」取最大，竖图会只占约
  // 70% 屏宽；这里改为按视口取最大，框宽度铺满可用区域。
  initialRectBuilder: InitialRectBuilder.withBuilder(
    (viewportRect, imageRect) => initialCropRect(
      viewportRect.size,
      widget.aspectRatio,
    ),
  ),
  ...
)
```

注意回调里的 `imageRect` 刻意不用：目标口径只依赖视口与比例，引入图片尺寸就会把缺陷的锚点又带回来。

### 纯函数：视口内取最大等比矩形

见 [media_display_layout.dart:41-51](file:///d:/developer/code/aicoding/s2s/lib/features/media/media_display_layout.dart#L41-L51)：

```dart
Rect initialCropRect(Size viewportSize, double aspectRatio) {
  final maxWidth = math.max(0.0, viewportSize.width - 2 * AppSpacing.sm);
  final maxHeight = math.max(0.0, viewportSize.height - 2 * AppSpacing.sm);
  final width = math.min(maxWidth, maxHeight * aspectRatio);
  final height = aspectRatio == 0 ? 0.0 : width / aspectRatio;
  return Rect.fromCenter(
    center: Offset(viewportSize.width / 2, viewportSize.height / 2),
    width: width,
    height: height,
  );
}
```

**8dp 边距的来由**：`AppSpacing.sm = 8`，见 [design_tokens.dart:194-195](file:///d:/developer/code/aicoding/s2s/lib/design_tokens.dart#L194-L195)。库的角点手柄是固定 32×32、以框角为中心的独立控件（`dotTotalSize = 32`，见 [constants.dart:1](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/constants.dart#L1)；控件尺寸见 [dot_control.dart:23-26](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/dot_control.dart#L23-L26)）。框边贴死视口时手柄有一半落在视口外、被裁掉或难点中；内缩一个间距单位既保住手柄的可见/可点区域，也只牺牲 16dp 宽度（1080 下仍是 95.9%）。

### 验证

真机 1080px 宽截图量得框 1036×574、比例 1.805；`flutter analyze` 0 issues；`flutter test` 804/804 通过（含新增 2 条几何测试）；release APK 重装后完成裁剪并重新上传成功。以上数字均为本次会话的真机/门禁实测记录，逐项见 [Batch1-进度记录.md:7461-7463](file:///d:/developer/code/aicoding/s2s/docs/progress/Batch1-进度记录.md#L7461-L7463)。修复随 main 的本次提交 e9e9cf9 落地（as of 2026-10-19）。

## Why This Works

按本次排查结论，库的初始化是两步：

1. **先算图片适配视口的矩形 `imageRect`**。`ReadyCropEditorViewState.prepared` 依 `imageSize.aspectRatio < viewportSize.aspectRatio` 选择 `VerticalCalculator` 或 `HorizontalCalculator`，见 [crop_editor_view_state.dart:54-63](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/crop_editor_view_state.dart#L54-L63)。竖图走 `VerticalCalculator.imageRect`，用 `height * imageRatio` 得到宽度、再水平居中，见 [calculator.dart:319-324](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/calculator.dart#L319-L324)。当图片比视口更「瘦」时，这个矩形比屏宽窄。
2. **默认框再以 `imageRect` 为锚取最大**。竖图且图片比例小于目标比例时，框宽 = `imageRect.width * sizeRatio`，见 [calculator.dart:335-339](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/calculator.dart#L335-L339)；框高按比例推出，然后居中。此时它已经把「图片适配宽度」当成了可用宽度的上界。

随后，`_resetCropRect` 在 `interactive` 为真时执行 `_applyScale(_readyState.scaleToCover)`，见 [crop.dart:485-487](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/crop.dart#L485-L487)，而 `scaleToCover = screenSize.width / imageRect.width`，见 [calculator.dart:350-352](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/calculator.dart#L350-L352)，必然 ≥ 1。图片被放大到铺满屏宽，但第 2 步算出的框坐标原样保留 —— 框不会随图片缩放重算，于是「图片铺满、框只占 71%」。

按视口计算则完全跳过了第 2 步对 `imageRect` 的依赖：传给 builder 的 `viewportRect` 在库内就是 `Rect.fromLTWH(0, 0, viewportSize.width, viewportSize.height)`，见 [crop.dart:463-474](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/crop.dart#L463-L474)，所以框宽天然等于「屏宽 − 16dp」，再由高度约束兜底（矮视口时改由高度决定宽度）。

**一个需要留意的口径**：库的 `viewportSize` 取自 `MediaQuery.of(context).size`（整屏），见 [crop.dart:422-423](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/crop.dart#L422-L423)，并不是 `Crop` 在页面里实际分到的布局区域。当前页面里 `Crop` 横向铺满，两者宽度相同，所以按视口算等价；若将来给 `Crop` 加左右内边距，这里必须改为按实际布局宽度计算，否则框会再次超出可见区域。

「框比 `imageRect` 宽」在缩放后的坐标系里是合法的：图片已按 `scaleToCover` 放大，可见范围覆盖整个视口，视口宽的框不会框到空白；落回源图时 `rectToCrop` 会把框坐标除以 `scale`，见 [crop_editor_view_state.dart:100-105](file:///c:/Users/刘杰/AppData/Local/Pub/Cache/hosted/pub.flutter-io.cn/crop_your_image-2.0.1/lib/src/widget/crop_editor_view_state.dart#L100-L105)，偏移和尺寸仍能正确映射到原图像素。

## Prevention

### 一、第三方控件暴露 `initial*Builder` 时，按容器断言，不按默认值断言

默认值很容易通过「比例对」「居中」这类弱断言，却过不了「宽度是否用满容器」。测试要直接对容器口径下断言：`rect.width == viewport.width - 2 * AppSpacing.sm`、`rect.height == rect.width / ratio`、中心等于视口中心，见 [media_display_layout_test.dart:15-25](file:///d:/developer/code/aicoding/s2s/test/features/media/media_display_layout_test.dart#L15-L25)。

### 二、纯函数测试覆盖「宽约束」与「高约束」两类视口

[media_display_layout_test.dart:27-36](file:///d:/developer/code/aicoding/s2s/test/features/media/media_display_layout_test.dart#L27-L36) 用 `Size(1080, 1800)` 锁「宽为约束」，用 `Size(1080, 300)` 锁「高为约束、宽按比例收缩且不超过可用宽」。`math.min` 的两条分支都要有测试，只测一种视口会让另一条分支悄悄失效。

### 三、验收必须用竖图源 + 真机量像素

本缺陷横图不可见、产物也不可见，唯一可靠的验收是：比例明显小于屏幕比例的长截图（如 1:3）→ 进入裁剪页 → 真机截图 → 量框宽/高并核对 `宽/高 ≈ 目标比例`。本次实测 1036/574 = 1.805，且框宽占屏宽 95.9%。

### 四、比例口径只留一份

`kDetailMediaBlockHeight` 与 `detailMediaAspectRatio()` 都在 [media_display_layout.dart:17-29](file:///d:/developer/code/aicoding/s2s/lib/features/media/media_display_layout.dart#L17-L29)，同时被详情页（[media_carousel.dart:95](file:///d:/developer/code/aicoding/s2s/lib/features/detail/media_carousel.dart#L95)）和裁剪入口（[media_section.dart:176](file:///d:/developer/code/aicoding/s2s/lib/features/publish/media_section.dart#L176)）引用；裁剪页只消费传入的 `aspectRatio`。这样详情卡尺寸或页边距一变，裁剪框自动跟随，不会各算一套而漂移。

### 五、把 8dp 边距写成「有意为之」

`initialCropRect` 的文档注释已写明这是圆点安全边距，见 [media_display_layout.dart:31-40](file:///d:/developer/code/aicoding/s2s/lib/features/media/media_display_layout.dart#L31-L40)。不写清的话，下一个人看到「框没有铺满 1080」会误以为同一个 bug 没修干净，从而删掉边距，换来角点手柄被视口裁掉。

## Related Issues

- [Figma Auto Layout 默认把描边计入布局：1px 描边造成 2px 高度差与横排底线错位](file:///d:/developer/code/aicoding/s2s/docs/solutions/ui-bugs/stroke-included-in-autolayout-2px-shift.md) —— 同族缺陷：几何由未显式赋值的平台/库默认值决定，修法都是显式覆盖默认值。
- [视觉稿的返工量正比于「无反馈期」长度：出图通道与守门探针都要在第一天就位](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/visual-feedback-loop-latency.md) —— 同一预防原则：布局默认行为要靠真实渲染尽早暴露。
