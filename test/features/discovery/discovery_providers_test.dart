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
import 'package:zhaoyazhao/features/discovery/discovery_providers.dart';
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

  PinsQuery queryWith(List<String> postTypes) => PinsQuery(
        leafCategoryIds: const [10101],
        postTypes: postTypes,
        radius: '5',
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
