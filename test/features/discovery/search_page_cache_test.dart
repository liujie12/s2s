/// 列表首屏缓存测试（2026-11-01 弱网兜底）。
///
/// 钉住三条会直接影响用户观感的行为：
/// - 同条件必须命中（否则弱网下等于没做）；
/// - 过期必须失效（帖子集合 60s 口径，见 `NfrCache.pinSetTtlSec`）；
/// - 容量按 LRU 淘汰（`NfrCache.maxKeys`），并保留「最近一份」给切换条件兜底。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/discovery/discovery_providers.dart';
import 'package:zhaoyazhao/features/discovery/search_page_cache.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

/// 构造一个与 [radius] 绑定的查询（不同 radius 即不同缓存键）。
///
/// 参数：[radius] 半径档字面量。
/// 返回：值相等语义可用的 [SearchQuery]。
SearchQuery _query(String radius) {
  return SearchQuery(
    leafCategoryIds: const [10101],
    postTypes: const ['resource'],
    radius: radius,
    gridId: '25866_8868',
    categoryVersion: '2026-08-31.1',
    lng: 116.397,
    lat: 39.909,
  );
}

/// 构造一个带命中数的空列表页状态。
///
/// 参数：[total] 命中总数（用于区分不同记录）。
/// 返回：[SearchPageState]。
SearchPageState _page(int total) {
  return SearchPageState(items: const [], total: total, nextPage: 2);
}

void main() {
  group('SearchPageCache', () {
    test('同条件命中：写入后能读回同一份第一页', () {
      final cache = SearchPageCache(nowMs: () => 0);
      final SearchQuery query = _query('3');
      cache.write(query, _page(7));

      expect(cache.read(_query('3'))?.total, 7);
      expect(cache.read(_query('5')), isNull, reason: '不同条件不得串用');
    });

    test('过期失效：超过 pinSetTtlSec 后读回 null', () {
      int now = 0;
      final cache = SearchPageCache(nowMs: () => now);
      cache.write(_query('3'), _page(1));

      now = NfrCache.pinSetTtlSec * 1000;
      expect(cache.read(_query('3'))?.total, 1, reason: 'TTL 边界内仍可用');

      now = NfrCache.pinSetTtlSec * 1000 + 1;
      expect(cache.read(_query('3')), isNull);
    });

    test('容量上限：超过 maxKeys 条按 LRU 淘汰最早写入的一条', () {
      final cache = SearchPageCache(nowMs: () => 0);
      final int overflow = NfrCache.maxKeys + 1;
      for (int i = 0; i < overflow; i++) {
        cache.write(_query('r$i'), _page(i));
      }

      expect(cache.read(_query('r0')), isNull, reason: '最早写入的被淘汰');
      expect(cache.read(_query('r1'))?.total, 1, reason: '只淘汰一条，次早的仍在');
      expect(cache.read(_query('r${overflow - 1}'))?.total, overflow - 1);
    });

    test('mostRecent：返回最近写入且未过期的一份（供切换条件兜底）', () {
      int now = 0;
      final cache = SearchPageCache(nowMs: () => now);
      cache.write(_query('3'), _page(3));
      cache.write(_query('5'), _page(5));

      expect(cache.mostRecent?.total, 5);

      now = NfrCache.pinSetTtlSec * 1000 + 1;
      expect(cache.mostRecent, isNull, reason: '过期后不得再顶住屏幕');
    });
  });
}
