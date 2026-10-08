/// 探索页仓库测试（[126] 前端段）。
///
/// 走 NetworkChainHarness 生产同款五拦截器链 + MockApiServer 真 HTTP 栈。
/// 断言两条链路的**请求形状**（五要素齐备、category_ids 逗号单参数、
/// 可选项缺省不传）与**响应解析**，以及信封业务错误（40001）经链上抛
/// [ApiException] 的形态。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/features/discovery/map_repository.dart';

import '../../support/api_envelope.dart';
import '../../support/mock_api_server.dart';
import '../../support/network_chain_harness.dart';

void main() {
  late NetworkChainHarness harness;
  late MapRepository repo;

  setUp(() async {
    harness = NetworkChainHarness(retrySleeper: (_) async {});
    await harness.start();
    repo = MapRepository(harness.dio);
  });

  tearDown(() async {
    await harness.dispose();
  });

  /// 构造一个最小可解析的 pins 响应体。
  Map<String, Object?> pinsPayload() => {
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
          [9001, 120.15120, 30.27550, 10101, 0, 2],
        ],
      };

  group('fetchPins', () {
    test('五要素按契约形状发出：category_ids 逗号单参数 + 其余齐备', () async {
      harness.stub('GET', '/api/v1/map/pins', (req) async {
        return MockResponse(body: ApiEnvelope.success(data: pinsPayload()));
      });

      final dto = await repo.fetchPins(
        categoryIds: const [10101, 10102],
        postType: 'resource',
        radius: '5',
        gridId: '26701_6727',
        categoryVersion: '2026-08-31.1',
        lng: 120.1551,
        lat: 30.2741,
        zoom: 14.5,
      );

      final query = Uri.parse(harness.server.lastRequest!.path).queryParameters;
      // style=form + explode=false：单个逗号连接参数，不是重复同名参数
      expect(query['category_ids'], '10101,10102');
      expect(query['post_type'], 'resource');
      expect(query['radius'], '5');
      expect(query['grid_id'], '26701_6727');
      expect(query['category_version'], '2026-08-31.1');
      expect(query['lng'], '120.1551');
      expect(query['lat'], '30.2741');
      expect(query['zoom'], '14.5');

      expect(dto.pins.single.id, 9001);
      expect(dto.pins.single.leafCategoryId, 10101);
    });

    test('信封业务错误（40001 五要素缺失）经链上抛 ApiException', () async {
      harness.stub('GET', '/api/v1/map/pins', (req) async {
        return MockResponse(
          status: 400,
          body: ApiEnvelope.failure(40001, '参数错误'),
        );
      });

      try {
        await repo.fetchPins(
          categoryIds: const [10101],
          postType: 'resource',
          radius: '5',
          gridId: '26701_6727',
          categoryVersion: '2026-08-31.1',
          lng: 120.1551,
          lat: 30.2741,
          zoom: 14.5,
        );
        fail('应抛出业务错误');
      } catch (error) {
        // EnvelopeInterceptor 以 DioException(error: ApiException) 承载（KTD2），
        // 拆包唯一入口是 harness.apiErrorOf。
        final apiError = harness.apiErrorOf(error);
        expect(apiError.code, ApiErrorCode.paramInvalid);
      }
    });
  });

  group('searchPosts', () {
    test('五要素 + 可选项透传（keyword/sort/page/page_size）', () async {
      harness.stub('GET', '/api/v1/posts/search', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(
            data: {
              'items': [
                {
                  'id': 9001,
                  'type': 'resource',
                  'title': '餐饮门店招服务员',
                  'completeness_level': 2,
                },
              ],
              'total': 1,
              'page': 2,
              'page_size': 20,
            },
          ),
        );
      });

      final page = await repo.searchPosts(
        categoryIds: const [10101],
        postType: 'resource',
        radius: 'city',
        gridId: '26701_6727',
        categoryVersion: '2026-08-31.1',
        lng: 120.1551,
        lat: 30.2741,
        keyword: '服务员',
        sort: 'distance',
        page: 2,
        pageSize: 20,
      );

      final query = Uri.parse(harness.server.lastRequest!.path).queryParameters;
      expect(query['category_ids'], '10101');
      expect(query['radius'], 'city');
      expect(query['keyword'], '服务员');
      expect(query['sort'], 'distance');
      expect(query['page'], '2');
      expect(query['page_size'], '20');

      expect(page.items.single.title, '餐饮门店招服务员');
      expect(page.page, 2);
    });

    test('可选项缺省时不出现在 query（空串会被服务端判非法值）', () async {
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

      await repo.searchPosts(
        categoryIds: const [10101],
        postType: 'demand',
        radius: '5',
        gridId: '26701_6727',
        categoryVersion: '2026-08-31.1',
        lng: 120.1551,
        lat: 30.2741,
      );

      final query = Uri.parse(harness.server.lastRequest!.path).queryParameters;
      expect(query.containsKey('keyword'), isFalse);
      expect(query.containsKey('sort'), isFalse);
      expect(query.containsKey('page'), isFalse);
      expect(query.containsKey('page_size'), isFalse);
    });
  });
}
