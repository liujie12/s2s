/// Pin 缓存键单测：语义搜索价格要素必须进键，否则会跨条件错命中。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/cache/pin_cache_key.dart';

void main() {
  test('无价格时与旧五要素键逐字一致（历史缓存继续命中）', () {
    expect(
      buildPinCacheKey(
        leafCategoryIds: const <int>[20102, 20101],
        postType: 'demand',
        radius: '1',
        gridId: '0_0',
        categoryVersion: '2026-08-31.1',
      ),
      'pins:20101,20102:demand:1:0_0:2026-08-31.1',
    );
  });

  test('带价格时追加价格后缀，且上下限不同即不同键', () {
    final onlyMax = buildPinCacheKey(
      leafCategoryIds: const <int>[20101],
      postType: 'demand',
      radius: '1',
      gridId: '0_0',
      categoryVersion: '2026-08-31.1',
      priceMax: 2000.0,
    );
    final range = buildPinCacheKey(
      leafCategoryIds: const <int>[20101],
      postType: 'demand',
      radius: '1',
      gridId: '0_0',
      categoryVersion: '2026-08-31.1',
      priceMin: 500.0,
      priceMax: 2000.0,
    );

    expect(onlyMax, 'pins:20101:demand:1:0_0:2026-08-31.1:p-2000.0');
    expect(range, isNot(onlyMax));
    expect(range, contains(':p500.0-2000.0'));
  });

  test('参数一致则键一致', () {
    String key() => buildPinCacheKey(
      leafCategoryIds: const <int>[20103, 20102, 20101],
      postType: 'demand',
      radius: '1',
      gridId: '26700_6728',
      categoryVersion: '2026-08-31.1',
      priceMax: 2000.0,
    );
    expect(key(), key());
  });

  test('小区 ID 进键：同条件不同小区不得复用缓存', () {
    String key(String? communityId) => buildPinCacheKey(
      leafCategoryIds: const <int>[20101],
      postType: 'demand',
      radius: '1',
      gridId: '0_0',
      categoryVersion: '2026-08-31.1',
      priceMax: 2000.0,
      communityId: communityId,
    );
    expect(key(null), isNot(key('B0FFG001')));
    expect(key('B0FFG001'), endsWith(':cB0FFG001'));
    expect(key(null), isNot(contains(':c')));
  });
}
