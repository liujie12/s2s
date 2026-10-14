/// ai 域仓库测试（B2-4 T2 AI 智能发布前端接线）。
///
/// 走 NetworkChainHarness 生产同款五拦截器链 + MockApiServer 真 HTTP 栈；
/// 断言：parse 契约载荷/响应解析、fetchQuota 查询参数、业务错误抛 ApiException。
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/ai/ai_dto.dart';
import 'package:zhaoyazhao/features/ai/ai_repository.dart';

import '../../support/api_envelope.dart';
import '../../support/mock_api_server.dart';
import '../../support/network_chain_harness.dart';

/// 构造 `POST /ai/publish/parse` 成功响应 data（契约 `AiParseResult`）。
///
/// 返回：[Map] 契约形态的 data（含 guess / scope_verified / unresolved_fields / quota）。
Map<String, Object?> parsePayload() => {
  'guess': {
    'title': '九成新实木餐桌',
    'leaf_category_id': 40101,
    'price': 350,
    'price_unit': '元',
    'template_values': {'condition': '几乎全新'},
  },
  'scope_verified': {
    'title': 'user_input',
    'leaf_category_id': 'platform',
    'price': 'user_input',
  },
  'unresolved_fields': <String>['pickup'],
  'quota': {
    'used': 3,
    'limit': 20,
    'reset_at': '2026-10-15T00:00:00Z',
  },
};

void main() {
  late NetworkChainHarness harness;
  late AiRepository repo;

  setUp(() async {
    harness = NetworkChainHarness(retrySleeper: (_) async {});
    await harness.start();
    repo = AiRepository(harness.dio);
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('parse', () {
    test('成功：解析出 guess / scope_verified / unresolved_fields / quota', () async {
      harness.stub('POST', '/api/v1/ai/publish/parse', (req) async {
        return MockResponse(body: ApiEnvelope.success(data: parsePayload()));
      });

      final result = await repo.parse(
        const AiParseRequestDto(
          text: '楼下超市卖苹果 5 元',
          kind: 'resource',
          leafCategoryId: 40101,
          completenessLevel: 1,
        ),
      );

      expect(result.guess.title, '九成新实木餐桌');
      expect(result.guess.leafCategoryId, 40101);
      expect(result.guess.price, 350);
      expect(result.guess.priceUnit, '元');
      expect(result.guess.templateValues, {'condition': '几乎全新'});
      expect(result.scopeVerified['title'], 'user_input');
      expect(result.unresolvedFields, ['pickup']);
      expect(result.quota!.used, 3);
      expect(result.quota!.limit, 20);
    });

    test('请求体：snake_case 且只含非 null 键', () async {
      harness.stub('POST', '/api/v1/ai/publish/parse', (req) async {
        return MockResponse(body: ApiEnvelope.success(data: parsePayload()));
      });

      await repo.parse(const AiParseRequestDto(text: '一句话', leafCategoryId: 40101));

      final body = harness.server.lastRequest!.body as Map<String, Object?>;
      expect(body['text'], '一句话');
      expect(body['leaf_category_id'], 40101);
      // 未提供的输入键一律不出现（避免服务端把 null 误判成「传了但为空」）
      expect(body.containsKey('media_id'), isFalse);
      expect(body.containsKey('voice_media_id'), isFalse);
      expect(body.containsKey('voice_text'), isFalse);
      expect(body.containsKey('kind'), isFalse);
      expect(body.containsKey('completeness_level'), isFalse);
    });

    test('业务错误（42901 配额耗尽）抛 ApiException', () async {
      harness.stub('POST', '/api/v1/ai/publish/parse', (req) async {
        return MockResponse(
          status: 429,
          body: ApiEnvelope.failure(42901, '今日 AI 额度已用完'),
        );
      });

      await expectLater(
        repo.parse(const AiParseRequestDto(text: '一句话')),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error',
            isA<ApiException>(),
          ),
        ),
      );
    });
  });

  group('fetchQuota', () {
    test('成功：查询参数按契约命名透传', () async {
      harness.stub('GET', '/api/v1/ai/publish/quota', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(
            data: {
              'used': 5,
              'limit': 30,
              'reset_at': '2026-10-15T00:00:00Z',
            },
          ),
        );
      });

      final quota = await repo.fetchQuota(completenessLevel: 2, leafCategoryId: 50101);

      expect(quota.used, 5);
      expect(quota.limit, 30);
      final query = harness.server.lastRequest!.path;
      expect(query, contains('completeness_level=2'));
      expect(query, contains('leaf_category_id=50101'));
    });

    test('未传可选参数时不带查询键', () async {
      harness.stub('GET', '/api/v1/ai/publish/quota', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(
            data: {
              'used': 0,
              'limit': 3,
              'reset_at': '2026-10-15T00:00:00Z',
            },
          ),
        );
      });

      await repo.fetchQuota();

      final path = harness.server.lastRequest!.path;
      expect(path, isNot(contains('completeness_level')));
      expect(path, isNot(contains('leaf_category_id')));
    });
  });
}
