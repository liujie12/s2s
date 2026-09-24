/// Pin 缓存键五要素自检与 Pin 缓存行为测试（前端设计 §16.2 / §16.1）。
///
/// 防的是「跨条件错命中」：五要素任一缺失仍拼键，会让切了分类/半径/网格后
/// 命中旧缓存，表现为地图上还是旧的点。自检必须在发请求前完成（§16.2）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/cache/pin_cache.dart';
import 'package:zhaoyazhao/core/cache/pin_cache_key.dart';

void main() {
  group('五要素自检', () {
    const valid = (
      leafCategoryIds: [10101, 10102],
      postType: 'resource',
      radius: '3',
      gridId: '26700_6728',
      categoryVersion: '2026-08-31.1',
    );

    test('齐备返回 true', () {
      expect(
        hasAllPinCacheElements(
          leafCategoryIds: valid.leafCategoryIds,
          postType: valid.postType,
          radius: valid.radius,
          gridId: valid.gridId,
          categoryVersion: valid.categoryVersion,
        ),
        isTrue,
      );
    });

    test('分类 ID 为空返回 false', () {
      expect(
        hasAllPinCacheElements(
          leafCategoryIds: const [],
          postType: valid.postType,
          radius: valid.radius,
          gridId: valid.gridId,
          categoryVersion: valid.categoryVersion,
        ),
        isFalse,
      );
    });

    test('任一字符串要素为空返回 false', () {
      expect(
        hasAllPinCacheElements(
          leafCategoryIds: valid.leafCategoryIds,
          postType: '',
          radius: valid.radius,
          gridId: valid.gridId,
          categoryVersion: valid.categoryVersion,
        ),
        isFalse,
      );
      expect(
        hasAllPinCacheElements(
          leafCategoryIds: valid.leafCategoryIds,
          postType: valid.postType,
          radius: '',
          gridId: valid.gridId,
          categoryVersion: valid.categoryVersion,
        ),
        isFalse,
      );
    });
  });

  test('分类 ID 排序后拼键：等价集合同一键', () {
    final a = buildPinCacheKey(
      leafCategoryIds: const [10102, 10101],
      postType: 'resource',
      radius: '3',
      gridId: '26700_6728',
      categoryVersion: '2026-08-31.1',
    );
    final b = buildPinCacheKey(
      leafCategoryIds: const [10101, 10102],
      postType: 'resource',
      radius: '3',
      gridId: '26700_6728',
      categoryVersion: '2026-08-31.1',
    );
    expect(a, b);
  });

  group('PinCache', () {
    test('put 后 get 命中，clearAll 后未命中', () {
      final cache = PinCache();
      cache.put('k1', 'v1');
      expect(cache.get('k1'), 'v1');
      cache.clearAll();
      expect(cache.get('k1'), isNull);
    });

    test('超容量按 LRU 淘汰最久未使用', () {
      final cache = PinCache(maxKeys: 2);
      cache.put('k1', 'v1');
      cache.put('k2', 'v2');
      cache.get('k1'); // 访问 k1，使其成为最近使用
      cache.put('k3', 'v3'); // 淘汰 k2
      expect(cache.get('k1'), 'v1');
      expect(cache.get('k2'), isNull);
      expect(cache.get('k3'), 'v3');
    });

    test('ttlSec=0 时写入即过期', () {
      final cache = PinCache(ttlSec: 0);
      cache.put('k1', 'v1');
      expect(cache.get('k1'), isNull);
    });
  });
}
