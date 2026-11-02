/// 列表首屏本地缓存（2026-11-01，弱网兜底）。
///
/// 背景（实测，非推断）：把「筛选要等几秒」逐段拆开后，服务端同参数查询
/// 稳定 0.18–0.26s、端上渲染 8ms，真正吃掉时间的是**手机到服务器的建连**
/// （同一手机 curl：DNS 6.8s、TLS 5.9s，链路丢包 25%；同一时刻 PC 仅 0.19s）。
/// 也就是说等待发生在「一个字节都还没到」的阶段，服务端再怎么优化也压不下去。
///
/// 因此列表首屏不再只依赖当次网络往返：
/// - **同条件命中**：同一 [SearchQuery] 上次成功的第一页直接渲染，随后后台
///   静默刷新覆盖（stale-while-revalidate），弱网下也能 1 秒内看到内容；
/// - **切换条件**：调用方可取 [mostRecent] 继续展示上一份结果，避免整屏
///   空白转圈，新结果到达后替换。
///
/// TTL 复用 [NfrCache.pinSetTtlSec]（帖子集合 60s）：与地图 Pin 同属
/// 「帖子集合」这一类易变内容，可见性口径一致，不新造第二个数字。
/// 容量复用 [NfrCache.maxKeys]，超出按 LRU 淘汰。
library;

import '../../nfr_constants.dart';
import 'discovery_providers.dart';

/// 一条缓存记录（第一页状态 + 写入时刻）。
class _Entry {
  /// 构造记录。
  ///
  /// 参数：[page] 第一页状态；[writtenAtMs] 写入时刻（毫秒时间戳）。
  _Entry(this.page, this.writtenAtMs);

  /// 第一页状态。
  final SearchPageState page;

  /// 写入时刻（毫秒时间戳）。
  final int writtenAtMs;
}

/// 列表首屏缓存（挂在非 autoDispose 的 Provider 上，活过页面与 pager 的销毁）。
class SearchPageCache {
  /// 构造缓存。
  ///
  /// 参数：[nowMs] 取当前毫秒时间戳的缝（测试注入固定时钟，避免真等 60s）。
  SearchPageCache({int Function()? nowMs})
      : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 时钟缝。
  final int Function() _nowMs;

  /// 条件 → 记录的映射；Dart 的 Map 保持插入顺序，LRU 淘汰取首个键。
  final Map<SearchQuery, _Entry> _entries = <SearchQuery, _Entry>{};

  /// 读取某条件的第一页缓存。
  ///
  /// 参数：[query] 请求条件（值相等语义，见 [SearchQuery]）。
  /// 返回：未命中/已过期返回 null；命中则同时把该键移到队尾（标记为最近使用）。
  SearchPageState? read(SearchQuery query) {
    final _Entry? entry = _entries.remove(query);
    if (entry == null) return null;
    if (_nowMs() - entry.writtenAtMs > NfrCache.pinSetTtlSec * 1000) {
      return null;
    }
    _entries[query] = entry;
    return entry.page;
  }

  /// 写入/覆盖某条件的第一页缓存，并按 [NfrCache.maxKeys] 做 LRU 淘汰。
  ///
  /// 参数：[query] 请求条件；[page] 刚成功拿到的第一页状态。
  /// 返回：无。
  void write(SearchQuery query, SearchPageState page) {
    _entries.remove(query);
    _entries[query] = _Entry(page, _nowMs());
    while (_entries.length > NfrCache.maxKeys) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// 最近一次写入且未过期的第一页（不区分条件）。
  ///
  /// 用途：切换筛选条件后首帧还没有新数据时，先接着展示上一份结果，
  /// 避免整屏空白转圈；新结果到达后由页面替换。
  /// 返回：无可用记录时返回 null。
  SearchPageState? get mostRecent {
    if (_entries.isEmpty) return null;
    return read(_entries.keys.last);
  }
}
