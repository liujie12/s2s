// 由 prototype-figma/export-dart-tokens.js 自动生成，请勿手改。
//
// 真源是 prototype-figma/code.js 顶部的六张 Token 表（同时也是 Figma Variables
// 集合 "ZhaoYaZhao Tokens" 的来源），改 Token 请改那里再重跑：
//
//     node prototype-figma/export-dart-tokens.js
//
// 每个常量上方的 /// 注释是它对应的 Figma 变量名，便于设计与实现对同一个名字
// 说话。prototype-figma/probe-token-vars.py 有断言逐项比对本文件与真源表，
// 手改或忘记重跑都会当场变红。
//
// 本文件刻意不 import 'package:flutter/material.dart'：颜色以 int 存
// 0xAARRGGBB，任何 Dart 项目都能直接引用，消费侧自行包 Color()。
//
// 计数：COLOR 26 + FLOAT 17 = 43

/// 语义色板（PRD §1.4.2）。对应 Figma 变量 color/*。
///
/// 用法：`Color(AppColors.primary)`
class AppColors {
  const AppColors._();

  /// color/primary  ·  #0B7C8C
  static const int primary = 0xFF0B7C8C;

  /// color/primary-dark  ·  #075E6B
  static const int primaryDark = 0xFF075E6B;

  /// color/primary-light  ·  #E6F6F8
  static const int primaryLight = 0xFFE6F6F8;

  /// color/accent  ·  #B4531A
  static const int accent = 0xFFB4531A;

  /// color/success  ·  #22C55E
  static const int success = 0xFF22C55E;

  /// color/warning  ·  #F59E0B
  static const int warning = 0xFFF59E0B;

  /// color/error  ·  #EF4444
  static const int error = 0xFFEF4444;

  /// color/success-text  ·  #15803D
  static const int successText = 0xFF15803D;

  /// color/warning-text  ·  #B45309
  static const int warningText = 0xFFB45309;

  /// color/error-text  ·  #B91C1C
  static const int errorText = 0xFFB91C1C;

  /// color/text-primary  ·  #1F2937
  static const int textPrimary = 0xFF1F2937;

  /// color/text-secondary  ·  #6B7280
  static const int textSecondary = 0xFF6B7280;

  /// color/text-placeholder  ·  #9CA3AF
  static const int textPlaceholder = 0xFF9CA3AF;

  /// color/border  ·  #E5E7EB
  static const int border = 0xFFE5E7EB;

  /// color/background  ·  #F8FAFC
  static const int background = 0xFFF8FAFC;

  /// color/surface  ·  #FFFFFF
  static const int surface = 0xFFFFFFFF;
}

/// 五大分类色（PRD §1.4.3）。对应 Figma 变量 category/*。
///
/// 不带后缀的是原色，只用于 Pin 填充、图例圆点、卡片圆标等**图形**用途；
/// `*Deep` 是深色变体，只用于**承载白色文字的底**（原色白字仅 2.54–4.23:1，
/// 五类全部不过 WCAG AA 4.5:1）。两者不可互换，详见 code.js 里 CATEGORY_DEEP
/// 的注释。
class AppCategoryColors {
  const AppCategoryColors._();

  /// category/cat-work  ·  #3B82F6
  static const int catWork = 0xFF3B82F6;

  /// category/cat-house  ·  #8B5CF6
  static const int catHouse = 0xFF8B5CF6;

  /// category/cat-vehicle  ·  #F97316
  static const int catVehicle = 0xFFF97316;

  /// category/cat-life  ·  #10B981
  static const int catLife = 0xFF10B981;

  /// category/cat-service  ·  #EC4899
  static const int catService = 0xFFEC4899;

  /// category/cat-work-deep  ·  #326FD1
  static const int catWorkDeep = 0xFF326FD1;

  /// category/cat-house-deep  ·  #8055E2
  static const int catHouseDeep = 0xFF8055E2;

  /// category/cat-vehicle-deep  ·  #B85510
  static const int catVehicleDeep = 0xFFB85510;

  /// category/cat-life-deep  ·  #0B825A
  static const int catLifeDeep = 0xFF0B825A;

  /// category/cat-service-deep  ·  #C63C81
  static const int catServiceDeep = 0xFFC63C81;
}

/// 一档字阶的三个属性。
///
/// weight 保留 PRD 原词（Bold / SemiBold / Regular / Medium），不预先映射成
/// FontWeight 数值 —— 具体选参由实现侧决定。
class AppTextStyleToken {
  const AppTextStyleToken({
    required this.size,
    required this.weight,
    required this.lineHeight,
  });

  /// 字号，单位逻辑像素
  final double size;

  /// 字重原词
  final String weight;

  /// 行高倍数
  final double lineHeight;

  /// 行高的像素值。
  ///
  /// 刻意只提供派生 getter 而不存字段：行高是「字号 × 倍数」的派生值，
  /// 单独存一份就是第二份副本，改了字号却忘改行高会静默不一致
  /// （同 code.js 里「行高不入 Variables」的理由）。
  double get lineHeightPx => size * lineHeight;
}

/// 字阶（PRD §1.4.4）。size 对应 Figma 变量 size/*；行高未入变量，为派生值。
class AppTypeScale {
  const AppTypeScale._();

  /// size/h1  ·  24px / Bold / ×1.3
  static const AppTextStyleToken h1 = AppTextStyleToken(size: 24, weight: 'Bold', lineHeight: 1.3);

  /// size/h2  ·  18px / SemiBold / ×1.3
  static const AppTextStyleToken h2 = AppTextStyleToken(size: 18, weight: 'SemiBold', lineHeight: 1.3);

  /// size/h3  ·  16px / SemiBold / ×1.4
  static const AppTextStyleToken h3 = AppTextStyleToken(size: 16, weight: 'SemiBold', lineHeight: 1.4);

  /// size/body  ·  14px / Regular / ×1.5
  static const AppTextStyleToken body = AppTextStyleToken(size: 14, weight: 'Regular', lineHeight: 1.5);

  /// size/small  ·  12px / Regular / ×1.5
  static const AppTextStyleToken small = AppTextStyleToken(size: 12, weight: 'Regular', lineHeight: 1.5);

  /// size/caption  ·  11px / Medium / ×1.2
  static const AppTextStyleToken caption = AppTextStyleToken(size: 11, weight: 'Medium', lineHeight: 1.2);
}

/// 间距阶（PRD §1.4.5）。对应 Figma 变量 spacing/*。
class AppSpacing {
  const AppSpacing._();

  /// spacing/xs
  static const double xs = 4;

  /// spacing/sm
  static const double sm = 8;

  /// spacing/md
  static const double md = 12;

  /// spacing/lg
  static const double lg = 16;

  /// spacing/xl
  static const double xl = 24;

  /// spacing/xxl
  static const double xxl = 32;
}

/// 圆角阶（PRD §1.4.5）。对应 Figma 变量 radius/*。
///
/// 类名不叫 Radius：Flutter 已有 `dart:ui` 的 Radius，同名会在消费侧撞车。
class AppRadius {
  const AppRadius._();

  /// radius/sm
  static const double sm = 4;

  /// radius/md
  static const double md = 8;

  /// radius/lg
  static const double lg = 12;

  /// radius/xl
  static const double xl = 16;

  /// radius/full
  static const double full = 999;
}
