/// 应用入口。
///
/// 三件事在此汇合（M4-2 脚手架范围）：
///   1. Riverpod 作用域（PRD §6.7 状态管理定案）；
///   2. go_router 路由表（PRD §10.1 页面清单）；
///   3. Design Token 主题（I2 产物 lib/design_tokens.dart，43 项）。
///
/// 注意：**此处刻意不初始化高德地图 SDK**。PRD §6.5.1 规定必须先获得隐私协议
/// 同意才能写入合规声明，未同意不得构建地图组件。在 main() 里图省事初始化
/// 会直接导致上架驳回（🔴）。同意后的写入点在 features/map/amap_init_guard.dart，
/// 由隐私协议门（features/privacy/privacy_gate_screen.dart）调用。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design_tokens.dart';
import 'router/app_router.dart';

void main() {
  runApp(const ProviderScope(child: ZhaoYaZhaoApp()));
}

/// 应用根组件。
///
/// 用 ConsumerWidget 而非 StatelessWidget：路由表需读取隐私同意状态来
/// 决定是否强制跳转协议门，故 routerConfig 来自 Provider。
class ZhaoYaZhaoApp extends ConsumerWidget {
  const ZhaoYaZhaoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: '找鸭找',
      routerConfig: ref.watch(routerProvider),
      theme: _buildTheme(),
      // 暗色模式与多语言本期不做（PRD §14.6 附近条目已明确）
      debugShowCheckedModeBanner: false,
    );
  }
}

/// 由 Design Token 构建 Material 主题。
///
/// 为什么集中在这里而非各页自己取 Token：颜色与字号一旦散落到各页，
/// Token 改动就无法一处生效，等于白做 Token 层。
/// 页面只在 Token 语义无法映射到 ThemeData 时才直接引用 AppColors。
///
/// 返回：配置好色板、字号与圆角的 ThemeData。
ThemeData _buildTheme() {
  const primary = Color(AppColors.primary);

  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
      primary: primary,
      // 显式指定而非让 fromSeed 推导：推导值与设计稿定稿色板会有偏差，
      // 而这些色值是经 WCAG 实测定稿的（条目 [43]），不能被算法改写
      surface: const Color(AppColors.surface),
      error: const Color(AppColors.error),
    ),
    scaffoldBackgroundColor: const Color(AppColors.background),
    dividerColor: const Color(AppColors.border),
    // 刻意不加 const：AppTypeScale.h1 等是自定义类 AppTextStyleToken 的实例，
    // Dart 的常量表达式不允许访问自定义类的属性（const_eval_property_access），
    // 若要加 const 就得把字号字面量抄进来，那会让 Token 失去单一真源。
    textTheme: TextTheme(
      headlineLarge: TextStyle(
        fontSize: AppTypeScale.h1.size,
        height: AppTypeScale.h1.lineHeight,
        color: Color(AppColors.textPrimary),
      ),
      titleLarge: TextStyle(
        fontSize: AppTypeScale.h2.size,
        height: AppTypeScale.h2.lineHeight,
        color: Color(AppColors.textPrimary),
      ),
      titleMedium: TextStyle(
        fontSize: AppTypeScale.h3.size,
        height: AppTypeScale.h3.lineHeight,
        color: Color(AppColors.textPrimary),
      ),
      bodyMedium: TextStyle(
        fontSize: AppTypeScale.body.size,
        height: AppTypeScale.body.lineHeight,
        color: Color(AppColors.textPrimary),
      ),
      bodySmall: TextStyle(
        fontSize: AppTypeScale.small.size,
        height: AppTypeScale.small.lineHeight,
        color: Color(AppColors.textSecondary),
      ),
      labelSmall: TextStyle(
        fontSize: AppTypeScale.caption.size,
        height: AppTypeScale.caption.lineHeight,
        color: Color(AppColors.textSecondary),
      ),
    ),
    cardTheme: CardThemeData(
      color: const Color(AppColors.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: const Color(AppColors.surface),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    ),
  );
}
