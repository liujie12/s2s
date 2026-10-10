/// 探索页 Provider 测试（[126] 前端段）。
///
/// 供需双选有两种形态，各钉一条（2026-10-08 二次裁定「方案 B」，取代原方案 1）：
/// - `pinsProvider`（`/map/pins` 只收单值）→ **两个并发单值请求**：断言请求条数、
///   各自的 `post_type`、以及合并结果（pins 拼接 + total 相加）；
/// - `searchPagerProvider`（`/posts/search` 收 1–2 个多值）→ **单次**请求：
///   断言 `post_type` 为一个逗号串，而非拆成两次。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/cache/pin_cache.dart';
import 'package:zhaoyazhao/core/cache/pin_cache_key.dart';
import 'package:zhaoyazhao/features/discovery/discovery_providers.dart';
import 'package:zhaoyazhao/features/discovery/map_dto.dart';
import 'package:zhaoyazhao/features/discovery/map_repository.dart';

import '../../support/api_envelope.dart';
import '../../support/mock_api_server.dart';
import '../../support/network_chain_harness.dart';

void main() {
  late NetworkChainHarness harness;
  late ProviderContainer container;

  /// 构造只含一条 pin 的 pins 响应体（id 随 post_type 区分，便于断言合并）。
  Map<String, Object?> pinsPayload(int id) => {
        'mode': 'pin',
        'total': 1,
        'schema': [
          'id',
          'lng',
          'lat',
          'category_id',
          'type',
          'completeness_level',
        ],
        'pins': [
          [id, 120.1512, 30.2755, 10101, 0, 2],
        ],
      };

  setUp(() async {
    harness = NetworkChainHarness(retrySleeper: (_) async {});
    await harness.start();
    container = ProviderContainer(
      overrides: [
        mapRepositoryProvider.overrideWithValue(MapRepository(harness.dio)),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    await harness.dispose();
  });

  /// 登记按 post_type 返回不同 id 的 pins 桩。
  void stubPinsByPostType() {
    harness.stub('GET', '/api/v1/map/pins', (req) async {
      final postType =
          Uri.parse(req.path).queryParameters['post_type'];
      return MockResponse(
        body: ApiEnvelope.success(
          data: pinsPayload(postType == 'demand' ? 2 : 1),
        ),
      );
    });
  }

  PinsQuery queryWith(List<String> postTypes, {String radius = '5'}) => PinsQuery(
        leafCategoryIds: const [10101],
        postTypes: postTypes,
        radius: radius,
        gridId: '26701_6727',
        categoryVersion: '2026-08-31.1',
        lng: 120.1551,
        lat: 30.2741,
        zoom: 14.5,
      );

  SearchQuery searchQueryWith(List<String> postTypes) => SearchQuery(
        leafCategoryIds: const [10101],
        postTypes: postTypes,
        radius: '5',
        gridId: '26701_6727',
        categoryVersion: '2026-08-31.1',
        lng: 120.1551,
        lat: 30.2741,
      );

  group('pinsProvider', () {
    test('双选：发两次请求（各带单值 post_type），合并 pins 与 total', () async {
      stubPinsByPostType();

      final merged =
          await container.read(pinsProvider(queryWith(const ['resource', 'demand'])).future);

      expect(harness.server.received, hasLength(2));
      final sentTypes = harness.server.received
          .map((r) => Uri.parse(r.path).queryParameters['post_type'])
          .toList();
      expect(sentTypes, containsAll(const ['resource', 'demand']));

      expect(merged.pins, hasLength(2));
      expect(merged.pins.map((p) => p.id), containsAll(const [1, 2]));
      expect(merged.total, 2);
      expect(merged.mode, 'pin');
    });

    test('单选：只发一次请求', () async {
      stubPinsByPostType();

      final merged =
          await container.read(pinsProvider(queryWith(const ['resource'])).future);

      expect(harness.server.received, hasLength(1));
      expect(merged.pins.single.id, 1);
      expect(merged.total, 1);
    });

    test('供需都不看（空列表）：零请求，返回空结果', () async {
      stubPinsByPostType();

      final merged = await container.read(pinsProvider(queryWith(const [])).future);

      expect(harness.server.received, isEmpty);
      expect(merged.pins, isEmpty);
      expect(merged.total, 0);
    });
  });

  group('pinsProvider 本地缓存（[146]）', () {
    /// 直接向缓存预置一条值，返回其键（便于断言 stale 后是否被清）。
    String seedCache(PinsQuery q, String postType, int id) {
      final key = buildPinCacheKey(
        leafCategoryIds: q.leafCategoryIds,
        postType: postType,
        radius: q.radius,
        gridId: q.gridId,
        categoryVersion: q.categoryVersion,
      );
      container.read(pinCacheProvider).put(key, PinsCompactDto.fromJson(pinsPayload(id)));
      return key;
    }

    test('命中本地缓存：不发请求，直接用缓存值', () async {
      stubPinsByPostType();
      final q = queryWith(const ['resource']);
      seedCache(q, 'resource', 9);

      final merged = await container.read(pinsProvider(q).future);

      expect(harness.server.received, isEmpty);
      expect(merged.pins.single.id, 9);
    });

    test('未命中：发请求并回写缓存；同键再取即命中', () async {
      stubPinsByPostType();
      final q = queryWith(const ['resource']);

      await container.read(pinsProvider(q).future);
      expect(harness.server.received, hasLength(1));

      // 让 Provider 重跑：缓存已回写，应命中且不再发请求。
      container.invalidate(pinsProvider(q));
      final merged = await container.read(pinsProvider(q).future);

      expect(harness.server.received, hasLength(1), reason: '第二次应整段命中缓存');
      expect(merged.pins.single.id, 1);
    });

    test('五要素变化（半径档不同）→ 不同键，重新请求', () async {
      stubPinsByPostType();

      await container
          .read(pinsProvider(queryWith(const ['resource'], radius: '5')).future);
      await container
          .read(pinsProvider(queryWith(const ['resource'], radius: '3')).future);

      expect(harness.server.received, hasLength(2));
    });

    test('双选：一份命中一份未命中 —— 只补发未命中的那一次', () async {
      stubPinsByPostType();
      final q = queryWith(const ['resource', 'demand']);
      seedCache(q, 'resource', 9);

      final merged = await container.read(pinsProvider(q).future);

      expect(harness.server.received, hasLength(1));
      expect(
        Uri.parse(harness.server.received.single.path)
            .queryParameters['post_type'],
        'demand',
      );
      expect(merged.pins.map((p) => p.id), containsAll(const [9, 2]));
      expect(merged.total, 2);
    });

    test('category_version_stale：全清缓存且不回写本次结果（§16.4）', () async {
      harness.stub('GET', '/api/v1/map/pins', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(
            data: {...pinsPayload(1), 'category_version_stale': true},
          ),
        );
      });
      final q = queryWith(const ['resource']);
      // 放一条**别的键**的旧值：本次是未命中（走了网络），stale 时必须把它一并清掉。
      final oldKey = seedCache(queryWith(const ['resource'], radius: '3'), 'resource', 7);

      final merged = await container.read(pinsProvider(q).future);
      final cache = container.read(pinCacheProvider);

      expect(merged.categoryVersionStale, isTrue);
      expect(cache.get(oldKey), isNull, reason: 'stale 触发全清');
      final ownKey = buildPinCacheKey(
        leafCategoryIds: q.leafCategoryIds,
        postType: 'resource',
        radius: q.radius,
        gridId: q.gridId,
        categoryVersion: q.categoryVersion,
      );
      expect(cache.get(ownKey), isNull, reason: '本次结果不得回写');
    });
  });

  group('searchPagerProvider', () {
    test('双选：只发一次请求，post_type 为逗号多值（排序与分页才是全局的）', () async {
      harness.stub('GET', '/api/v1/posts/search', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(
            data: {
              'items': <Object?>[],
              'total': 0,
              'page': 1,
              'page_size': 20,
            },
          ),
        );
      });

      await container.read(
        searchPagerProvider(searchQueryWith(const ['resource', 'demand'])).future,
      );

      // 若哪天又改回「拆两次单值请求」，这里会拿到 2 与 'demand' 而失败。
      expect(harness.server.received, hasLength(1));
      expect(
        Uri.parse(harness.server.received.single.path)
            .queryParameters['post_type'],
        'resource,demand',
      );
    });
  });

  group('PinsQuery 值相等（请求去重的前提）', () {
    test('同视口两次构造相等 —— 相机静止后重复同步不会多发请求', () {
      expect(
        queryWith(const ['resource', 'demand']),
        queryWith(const ['resource', 'demand']),
      );
    });

    test('视口不同即不等 —— 否则换了区域也不会重新取数', () {
      final other = PinsQuery(
        leafCategoryIds: const [10101],
        postTypes: const ['resource', 'demand'],
        radius: '5',
        gridId: '26701_6727',
        categoryVersion: '2026-08-31.1',
        lng: 120.26,
        lat: 30.2741,
        zoom: 14.5,
      );

      expect(queryWith(const ['resource', 'demand']), isNot(other));
    });
  });
}
