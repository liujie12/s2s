/// Pin 集合内存缓存（前端设计 §16.1 / §10.2.1）。
///
/// Pin 集合按网格分键，用户一路滑动会产生大量键；不设上限会把内存撑爆并拖慢。
/// 因此以内存 LRU 为主，容量上限 [NfrCache.maxKeys]，超限按最近未使用淘汰。
/// TTL 用 [NfrCache.pinSetTtlSec]（秒级，易变数据）；跨启动不持久化——Pin 缓存
/// 本就不需要跨进程存活，且 §10.2.1 明确 Pin 缓存**不放 `shared_preferences`**
/// （那是同步全量加载，会拖慢启动）。
///
/// 收到服务端 `category_version_stale: true` 后调用 [clearAll] 全清——旧版本号
/// 下的键已不可信（前端设计 §16.4）。
library;

import '../../nfr_constants.dart';

/// 缓存项：值 + 写入时间（判定 TTL 过期）。
class _Entry {
  const _Entry(this.value, this.storedAt);

  final Object value;
  final DateTime storedAt;
}

/// Pin 集合内存缓存（LRU + TTL + 全清）。
class PinCache {
  PinCache({
    int maxKeys = NfrCache.maxKeys,
    int ttlSec = NfrCache.pinSetTtlSec,
  })  : _maxKeys = maxKeys,
        _ttlSec = ttlSec;

  /// 容量上限（默认 [NfrCache.maxKeys]）。
  final int _maxKeys;

  /// TTL 秒数（默认 [NfrCache.pinSetTtlSec]）。
  final int _ttlSec;

  /// 有序映射承载 LRU：访问即移末尾，淘汰从队首取。
  final _entries = <String, _Entry>{};

  /// 取缓存值；未命中或已过期返回 null。
  ///
  /// [key] 缓存键（经 `buildPinCacheKey` 生成）
  ///
  /// 返回：缓存值，命中且未过期时非空
  Object? get(String key) {
    final entry = _entries.remove(key);
    if (entry == null) {
      return null;
    }
    if (DateTime.now().difference(entry.storedAt).inSeconds >= _ttlSec) {
      return null;
    }
    // 命中则移末尾（LRU 最近使用语义）。
    _entries[key] = entry;
    return entry.value;
  }

  /// 写入缓存值；超容量时淘汰最久未使用的键。
  ///
  /// [key]   缓存键
  /// [value] 缓存值
  void put(String key, Object value) {
    _entries.remove(key);
    _entries[key] = _Entry(value, DateTime.now());
    while (_entries.length > _maxKeys) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 全清缓存（收到 `category_version_stale` 后调用）。
  void clearAll() => _entries.clear();
}
