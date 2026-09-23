/// Token 持久化提供者（详细设计 KTD7 / 计划 U10）。
///
/// 职责边界（严格）：本类只负责「会话 JSON 字符串」的安全读写，
/// **不感知 [AuthSession] 类型**（core 层不 import features，KTD5 反向
/// 依赖禁止）。序列化（AuthSession ↔ JSON）由 features 侧
/// `auth_repository.dart` 承载，本类拿到的只是「一个不透明的字符串」。
/// 这样 core 保持对 features 的零依赖，且换存储介质时只改本类。
///
/// 为什么用 [FlutterSecureStorage] 而非 [SharedPreferences]（KTD7）：
///   - Token 是登录凭证，明文落盘（SharedPreferences XML）在 root/越狱
///     设备上可被直接读取，等同于把登录态钥匙放在门口地垫下；
///   - Android 走 Keystore 加密、iOS 走 Keychain，两者都是系统级安全
///     存储，Token 不以明文出现在任何文件里。
///   - 与本仓 device_id/privacy 用 SharedPreferences 不冲突：那两处存的
///     是「不可用于鉴权的设备标识/同意态」，敏感度低于登录凭证。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 会话 Token 的本地安全存储。
class TokenStorage {
  /// 构造存储。
  ///
  /// 参数：
  ///   [storage] 可选的 [FlutterSecureStorage] 实例（测试注入用）；生产
  ///             为 null 时用默认构造（Android Keystore / iOS Keychain）。
  TokenStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// 持久化键名（带 `s2s.` 前缀，与 device_id/privacy 的键名约定一致）。
  static const String sessionKey = 's2s.auth.session';

  /// 底层安全存储实例。
  final FlutterSecureStorage _storage;

  /// 写入会话 JSON 字符串。
  ///
  /// 参数：[json] 会话序列化后的 JSON 字符串（由 features 侧产出）。
  /// 返回：[Future<void>] 写入完成。
  Future<void> save(String json) async {
    await _storage.write(key: sessionKey, value: json);
  }

  /// 读取会话 JSON 字符串。
  ///
  /// 返回：[Future<String?>] 会话 JSON；未登录/未写入时为 null。
  Future<String?> read() => _storage.read(key: sessionKey);

  /// 清除会话（登出/会话失效）。
  ///
  /// 返回：[Future<void>] 删除完成。
  Future<void> clear() => _storage.delete(key: sessionKey);
}

/// 会话存储 Provider（core 层装配，供 features 侧 AuthSessionNotifier 注入）。
///
/// 生产用默认 [TokenStorage]（Android Keystore / iOS Keychain）；测试经
/// `overrideWithValue` 注入带 mock [FlutterSecureStorage] 的实例。
final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());
