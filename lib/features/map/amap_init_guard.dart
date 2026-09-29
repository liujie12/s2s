/// 高德地图 SDK 合规守卫（PRD §6.5.1、§6.7 `:1235`、§14.6 `:2287`）。
///
/// **重要实测结论（2026-08-27，读 amap_map 1.0.15 源码得出）**：
/// `AMapInitializer.updatePrivacyAgree()` **不触发任何原生调用**，
/// 它只是给 Dart 侧静态变量赋值（`amap_initializer.dart:41-43`）。
/// 真正把声明传给原生、并拉起地图 SDK 的动作发生在
/// **`AMapWidget` 构建时**（`amap_widget.dart:179` 读取该变量塞进 creationParams）。
///
/// 由此得出合规的真实判据：
///
/// > **未同意时不得构建 `AMapWidget`** —— 而不是「不调 updatePrivacyAgree」。
///
/// 所以本守卫有两层职责，缺一不可：
/// 1. [applyConsent]：把同意声明写进 SDK（值必须三项全 true，否则白屏）；
/// 2. [canRenderMap]：地图页构建前必须查询它，false 时渲染降级底图。
///
/// 若只做第 1 层，仍可能在未同意时构建 Widget 而触发原生初始化 —— 那是
/// 抓包实测会当场暴露的驳回项（§14.6）。
library;

import 'package:amap_map/amap_map.dart';
import 'package:flutter/widgets.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../privacy/privacy_consent.dart';

/// 高德 Android Key 的 `--dart-define` 变量名（全工程唯一真源）。
///
/// 为什么 Key 不进仓库：架构 §9.2 与编码规范 §110 要求客户端地图 Key 仅
/// **构建期注入**、仓库只留占位。构建命令形如
/// `flutter run --dart-define=AMAP_ANDROID_KEY=<你的Key>`（也可写在未被 git 跟踪的
/// 本地脚本里）。Key 与包名 `com.s2s.zhaoyazhao.dev` 绑定，改包名须重申。
const String kAmapAndroidKeyDefine = 'AMAP_ANDROID_KEY';

/// 构建期注入的 Android Key。未注入时为空串 —— 此时必须走降级底图。
const String _kAndroidKey = String.fromEnvironment(kAmapAndroidKeyDefine);

/// 高德地图 SDK 合规守卫。
class AMapInitGuard {
  const AMapInitGuard._();

  static bool _consentApplied = false;

  /// 高德插件是否已拿到 Key（`AMapInitializer.init` 已调用）。
  static bool _sdkInitialized = false;

  /// 同意声明是否已写入 SDK。
  static bool get isConsentApplied => _consentApplied;

  /// 构建期是否注入了高德 Key。
  ///
  /// 为 false 时地图页**必须**渲染降级底图：没有 Key 时构建 `AMapWidget` 会白屏，
  /// 而白屏与「隐私声明未写」的表现完全一致，排查时极易误判（见 amap_init_guard 头注）。
  static bool get hasApiKey => _kAndroidKey.isNotEmpty;

  /// 把构建期注入的 Key 交给高德插件。
  ///
  /// 为什么由本守卫统一持有：Key 与合规声明同属「地图 SDK 的全局一次性配置」，
  /// 散落到地图页会让「init 必须先于 AMapWidget 构建」变成隐式约定 ——
  /// 插件是在**构建 `AMapWidget`** 时才把 `apiKey` 塞进 creationParams 的
  /// （`amap_widget.dart:180`），顺序错了就是白屏。
  ///
  /// 幂等：重复调用只做一次真实初始化。
  ///
  /// 参数：
  /// - [context]：高德插件用它取资源密度（内部走 `AMapUtil.init`）。
  ///
  /// 返回：true 表示 Key 已就绪、可构建 `AMapWidget`；false 表示未注入 Key，
  /// 调用方须改渲染降级底图。
  static bool ensureSdkInitialized(BuildContext context) {
    if (!hasApiKey) return false;
    if (_sdkInitialized) return true;

    AMapInitializer.init(
      context,
      apiKey: const AMapApiKey(androidKey: _kAndroidKey),
    );
    _sdkInitialized = true;
    return true;
  }

  /// 在用户同意隐私协议后，把合规声明写入高德 SDK。
  ///
  /// 参数：
  /// - [status]：当前隐私同意态，必须为 [PrivacyConsentStatus.agreed] 才执行。
  ///
  /// 返回：实际写入返回 true；因未同意或已写入而跳过返回 false。
  ///
  /// 为什么传入同意态而非在内部读 Provider：让「调用方必须先拿到同意状态」
  /// 成为签名上可见的约束，而不是藏在函数体里的隐式依赖。
  static bool applyConsent(PrivacyConsentStatus status) {
    // 🔴 红线：本方法是全应用唯一允许调用 updatePrivacyAgree 的位置。
    // 未同意直接返回，不得有"先初始化后补同意"之类的分支。
    if (status != PrivacyConsentStatus.agreed) return false;
    if (_consentApplied) return false;

    // 三项必须全为 true。任一为 false 都会导致地图白屏
    // （amap_initializer.dart:37 原文），且白屏表现与「Key 未配置」
    // 完全一致，排查时极易误判为 Key 问题。
    AMapInitializer.updatePrivacyAgree(
      const AMapPrivacyStatement(
        hasContains: true,
        hasShow: true,
        hasAgree: true,
      ),
    );
    _consentApplied = true;
    return true;
  }

  /// 是否允许构建 `AMapWidget`。
  ///
  /// 参数：
  /// - [status]：当前隐私同意态。
  ///
  /// 返回：true 表示可渲染真实地图；false 表示必须渲染降级底图（PRD `:1207`）。
  ///
  /// 这是合规闸门的真正位置 —— 构建 `AMapWidget` 即触发原生 SDK 初始化。
  static bool canRenderMap(PrivacyConsentStatus status) =>
      status == PrivacyConsentStatus.agreed && _consentApplied;
}
