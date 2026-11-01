/// 站内消息图标（双层对话气泡 · 24dp 评审选定方案 C）。
///
/// **唯一实现处**（编码规范 §1.2）：底部 Tab、消息列表空态、详情页「发消息」
/// 键共用同一份几何 —— 这三处表达的是同一个概念「站内会话」，各画一份会让
/// 形状在后续改动中悄悄漂移。
///
/// 视觉来源：评审页 `docs/design/ui/message-icon-options.html` 的 C 方案，
/// 与设计稿 `docs/design/ui/message-center.html` §01 同源。
library;

import 'package:flutter/material.dart';

/// 双层对话气泡图标（后层会话 + 前层会话，前层带左下小尾巴）。
class MessageBubbleIcon extends StatelessWidget {
  /// 构造消息图标。
  ///
  /// 参数：[color] 描边色（选中主色 / 未选中次要文字色，由调用方决定）；
  ///   [size] 图标边长，默认 24dp（详情页按钮用 18dp）。
  const MessageBubbleIcon({super.key, required this.color, this.size = 24});

  /// 描边色。
  final Color color;

  /// 图标边长。
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _MessageBubblePainter(color),
    );
  }
}

/// 双层气泡描边绘制器。
///
/// 几何取自评审页 C 方案（viewBox 24×24、描边 1.8）：
///   - 后层：`M8.2 4.4h8.1a2.6 2.6 0 0 1 2.6 2.6v4.4`（不闭合，避免 24px 下与前层糊团）；
///   - 前层：圆角 2.2 的气泡 + 左下尾巴（尾巴尖落在 (6.4, 19.9)）。
/// 绘制前把画布缩放到 `size/24`，坐标直接沿用 SVG 原文，避免逐坐标缩放引入笔误。
class _MessageBubblePainter extends CustomPainter {
  const _MessageBubblePainter(this.color);

  /// 描边色。
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    // 后层：只画左上两条边与右竖线，暗示「还有一个会话」。
    final Path back = Path()
      ..moveTo(8.2, 4.4)
      ..lineTo(16.3, 4.4)
      ..arcToPoint(
        const Offset(18.9, 7.0),
        radius: const Radius.circular(2.6),
        clockwise: true,
      )
      ..lineTo(18.9, 11.4);
    // 前层：完整气泡（圆角 2.2）+ 左下尾巴。
    final Path front = Path()
      ..moveTo(4.4, 9.1)
      ..lineTo(14.6, 9.1)
      ..arcToPoint(
        const Offset(16.8, 11.3),
        radius: const Radius.circular(2.2),
        clockwise: true,
      )
      ..lineTo(16.8, 15.2)
      ..arcToPoint(
        const Offset(14.6, 17.4),
        radius: const Radius.circular(2.2),
        clockwise: true,
      )
      ..lineTo(9.6, 17.4)
      ..lineTo(6.4, 19.9)
      ..lineTo(6.4, 17.4)
      ..lineTo(4.4, 17.4)
      ..arcToPoint(
        const Offset(2.2, 15.2),
        radius: const Radius.circular(2.2),
        clockwise: true,
      )
      ..lineTo(2.2, 11.3)
      ..arcToPoint(
        const Offset(4.4, 9.1),
        radius: const Radius.circular(2.2),
        clockwise: true,
      )
      ..close();
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawPath(back, stroke);
    canvas.drawPath(front, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MessageBubblePainter oldDelegate) =>
      oldDelegate.color != color;
}
