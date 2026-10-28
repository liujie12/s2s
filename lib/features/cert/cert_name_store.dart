/// 常用证书名称候选（内置常量 + 本机记住的自定义名）。
///
/// 口径（2026-10-28 产品裁定）：资质简化为「名称 + 图片」，不再有证件类型，
/// 故候选是**一份全局常用证名**，不按类型分组。
///
/// 内置候选是常量（所有用户可见）；用户自填的新名称只在本机记住、只有本人可见
/// —— 存储键带 `userId`，不上报、不跨设备同步。
///
/// 与档案数据的边界：这里存的是**输入便利的候选**，不是档案本身；档案里的证名
/// 仍以 `cert` 表为准（`GET /cert/status` 的 `cert_name`）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../nfr_constants.dart';

/// 内置常用证名（2026-10-28 产品给定 10 项，不按类型分组）。
const List<String> kCertNameSuggestions = <String>[
  '家政服务资质',
  '养老护理员证',
  '育婴员证',
  '月嫂证',
  '保洁员证',
  '营业执照',
  '开户许可证',
  '机动车行驶证',
  '机动车驾驶证',
  '道路运输经营许可证',
];

/// 自定义证件名称的本地记忆。
class CertNameStore {
  /// 构造无状态存储（每次读写即时取 SharedPreferences，不缓存实例）。
  const CertNameStore();

  /// 键名前缀（带 `s2s.` 前缀避免与插件写入的键冲突）。
  static const String _keyPrefix = 's2s.cert.names';

  /// 读取该用户在本机记住的自定义名称（最近使用优先）。
  ///
  /// 参数：[userId] 会话用户 ID。
  /// 返回：[List<String>]；无记录时为空列表。
  Future<List<String>> read(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_keyOf(userId)) ?? const <String>[];
  }

  /// 记住一个用户自定义的名称（重复即置顶，超出上限淘汰最旧）。
  ///
  /// 参数：
  ///   [userId] 会话用户 ID；
  ///   [name] 待记住的名称（空白忽略）；
  ///   [exclude] 不落库的名称集合（内置候选，已在界面上永久提供）。
  /// 返回：[Future<void>]。
  Future<void> remember(
    String userId,
    String name, {
    Iterable<String> exclude = const <String>[],
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || exclude.contains(trimmed)) return;
    final prefs = await SharedPreferences.getInstance();
    final key = _keyOf(userId);
    final current = prefs.getStringList(key) ?? const <String>[];
    final next = <String>[
      trimmed,
      for (final item in current)
        if (item != trimmed) item,
    ];
    final capped = next.length > NfrCert.rememberedNameLimit
        ? next.sublist(0, NfrCert.rememberedNameLimit)
        : next;
    await prefs.setStringList(key, capped);
  }

  /// 计算存储键（全局一份证名，只有用户维度）。
  ///
  /// 参数：[userId] 用户 ID。
  /// 返回：[String]。
  static String _keyOf(String userId) => '$_keyPrefix.$userId';
}

/// 自定义证名存储 Provider。
final certNameStoreProvider = Provider<CertNameStore>(
  (ref) => const CertNameStore(),
);
