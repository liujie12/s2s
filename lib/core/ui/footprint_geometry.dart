/// fp0 脚印几何真源（三趾 + 掌形贝塞尔）。
///
/// 坐标与 `prototype-figma/assets/duck-symbol-inverse.svg`、
/// `footprint-standalone.svg`、Android 图标生成脚本 `build_android_foonote.py`
/// 共用同一份 fp0 原文（0..108 × 0..90 坐标系，由使用方自行
/// translate(-54,-45) 居中、rotate、scale）。2026-11-02 登录页品牌区接入
/// 脚印后出现第二处使用，按编码规范 §1.1「第二处即抽取」收敛到此文件，
/// 各处禁再复制几何字面量。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// fp0 脚印几何（仅几何，不含颜色与位置变换）。
class FootprintGeometry {
  const FootprintGeometry._();

  /// 三趾参数（每个趾自身再自转）：(趾心 cx, 趾心 cy, 横向半径 rx, 纵向半径 ry, 自转角度°)。
  static const List<(double, double, double, double, double)> toes = [
    (40.0, 35.0, 7.2, 9.8, -15.0), // 左趾
    (54.0, 30.5, 7.6, 10.6, 0.0), // 中趾
    (68.0, 35.0, 7.2, 9.8, 15.0), // 右趾
  ];

  /// 在当前 canvas 状态下绘制整只 fp0 脚印（三趾 + 掌形）。
  ///
  /// 调用方负责位置/旋转/缩放变换与 [paint] 颜色；本方法内部 save/restore 平衡。
  ///
  /// 参数：[canvas] 已完成定位变换的画布；[paint] 填充画刷。
  /// 返回：void。
  static void paint(Canvas canvas, Paint paint) {
    for (final toe in toes) {
      final (tcx, tcy, rx, ry, selfRot) = toe;
      canvas.save();
      canvas
        ..translate(tcx, tcy)
        ..rotate(selfRot * math.pi / 180);
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2),
        paint,
      );
      canvas.restore();
    }
    canvas.drawPath(palmPath(), paint);
  }

  /// fp0 掌形贝塞尔 path，坐标逐字对应 Python 版 FP_PALM_PATH_D。
  ///
  /// 返回：[Path] 闭合掌形路径。
  static Path palmPath() {
    return Path()
      ..moveTo(37, 57)
      ..cubicTo(37, 50.5, 44.5, 48.5, 54, 48.5)
      ..cubicTo(63.5, 48.5, 71, 50.5, 71, 57)
      ..cubicTo(71, 62.5, 67.5, 66.5, 64, 72)
      ..cubicTo(60.5, 78, 59.5, 84, 54, 84)
      ..cubicTo(48.5, 84, 47.5, 78, 44, 72)
      ..cubicTo(40.5, 66.5, 37, 62.5, 37, 57)
      ..close();
  }
}
