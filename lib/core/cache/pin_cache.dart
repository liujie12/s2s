/// Pin 集合内存缓存（前端设计 §16.1 / §10.2.1）。
///
/// Pin 集合按网格分键，用户一路滑动会产生大量键；不设上限会把内存撑爆并拖慢。
/// 因此以内存 LRU 为主，容量上限 [NfrCache.maxKeys]，超限按最近未使用淘汰。
/// TTL 用 [NfrCache.pinSetTtlSec]（秒级，易变数据）；跨启动不持久化——Pin 缓存
/// 本就不需要跨进程存活，且 §10.2.1 明确 Pin 缓存**不放 `shared_preferences`**
/// （那是同步全量加载，会拖慢启动）。
///
/// **TTL 分档口径（2026-09-02 定案，禁回退为按类目层级分档）**：Pin 集合 TTL 是
/// 单一档 [NfrCache.pinSetTtlSec]（60s），**不按「大类/二级/三级」分 1h·15min·5min**。
/// 原按层级分档的写法（PRD §6.10 原表）已推翻：五要素缓存键中没有任何一项随
/// 「帖子集合变化」而变（版本号只随运营改分类树变），按层级分档会让新发布最长
/// 1h 别人看不见、已下架 Pin 最长 1h 仍在图上，与 §9.10.3「风险分≥60 自动下架 +
/// 4h 工单 SLA」的治理承诺直接冲突。1h/15min/5min 三档保留给**静态数据**
/// （见 [NfrCache.staticL1TtlSec] 等，非本类）。
///
/// 收到服务端 `category_version_stale: true` 后调用 [clearAll] 全清——旧版本号
/// 下的键已不可信（前端设计 §16.4）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Pin 集合缓存的全局单例（[146]：此前 `PinCache` 建成但**无调用方**，
/// 故缓存段恒 0、命中类会话不存在）。
///
/// **不能 autoDispose**：缓存要在「地图页切走 → 重建」之间存活，随监听者销毁
/// 等于每次进页面都从零开始，命中率恒为 0 —— 正是本条要消除的状态。
/// 不落盘的取舍见文件头（§10.2.1 禁 `shared_preferences`）。
final pinCacheProvider = Provider<PinCache>((ref) => PinCache());
