/// 本机记住的「自定义证件名称」（按 用户 + 资质类型 隔离）。
///
/// 口径（2026-10-28 用户裁定）：用户新增的证名要记住，但**不能成为其他用户的
/// 候选**。故存储键带上 `userId`，且只在本机保存 —— 不上报、不跨设备同步。
///
/// 与档案数据的边界：这里存的是**输入便利的候选**，不是档案本身；档案里的证名
/// 仍以 `cert` 表为准（`GET /cert/status` 的 `cert_name`）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../nfr_constants.dart';

/// 自定义证件名称的本地记忆。
class CertNameStore {
  /// 构造无状态存储（每次读写即时取 SharedPreferences，不缓存实例）。
  const CertNameStore();

  /// 键名前缀（带 `s2s.` 前缀避免与插件写入的键冲突）。
  static const String _keyPrefix = 's2s.cert.names';

  /// 读取该用户在该类型下记住的名称（最近使用优先）。
  ///
  /// 参数：[userId] 会话用户 ID；[certType] 契约 `CertTypeEnum` 值。
  /// 返回：[List<String>]；无记录时为空列表。
  Future<List<String>> read(String userId, String certType) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_keyOf(userId, certType)) ?? const <String>[];
  }

  /// 记住一个用户自定义的名称（重复即置顶，超出上限淘汰最旧）。
  ///
  /// 参数：
  ///   [userId] 会话用户 ID；
  ///   [certType] 契约类型值；
  ///   [name] 待记住的名称（空白忽略）；
  ///   [exclude] 不落库的名称集合（内置候选，已在界面上永久提供）。
  /// 返回：[Future<void>]。
  Future<void> remember(
    String userId,
    String certType,
    String name, {
    Iterable<String> exclude = const <String>[],
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || exclude.contains(trimmed)) return;
    final prefs = await SharedPreferences.getInstance();
    final key = _keyOf(userId, certType);
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

  /// 计算存储键。
  ///
  /// 参数：[userId] 用户 ID；[certType] 契约类型值。
  /// 返回：[String]。
  static String _keyOf(String userId, String certType) =>
      '$_keyPrefix.$userId.$certType';
}

/// 自定义证名存储 Provider。
final certNameStoreProvider = Provider<CertNameStore>(
  (ref) => const CertNameStore(),
);
