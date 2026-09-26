/// post 域仓库与契约 DTO 测试（[124]/[125] 前端段 / B4）。
///
/// 走 NetworkChainHarness 生产同款五拦截器链 + MockApiServer 真 HTTP 栈
/// （后端就绪切 baseUrl 断言一行不改）。断言 precheck 的契约口径：
/// 通过（passed=true）/ 阻断（200 + code=0 + blocks 五码一次性给全）/
/// 链路错误（信封业务错误抛 ApiException）三种形态，以及载荷透传。
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/post/post_repository.dart';

import '../../support/api_envelope.dart';
import '../../support/mock_api_server.dart';
import '../../support/network_chain_harness.dart';
import '../../support/post_fixtures.dart';

void main() {
  late NetworkChainHarness harness;
  late PostRepository repo;

  setUp(() async {
    harness = NetworkChainHarness(retrySleeper: (_) async {});
    await harness.start();
    repo = PostRepository(harness.dio);
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('precheck 通过', () {
    test('passed=true 空 blocks，可选 completeness_level 解析为 2', () async {
      stubPrecheck(harness, precheckPassedPayload());

      final result = await repo.precheck(const {});

      expect(result.passed, isTrue);
      expect(result.blocks, isEmpty);
      expect(result.completenessLevel, 2);
      expect(harness.server.received, hasLength(1));
    });

    test('PostDraft 载荷原样透传到请求体', () async {
      stubPrecheck(harness, precheckPassedPayload());
      final draft = <String, Object?>{
        'type': 'resource',
        'leaf_category_id': 10101,
        'title': '火锅店招服务员',
        'attributes': {'headcount': '3'},
        'contact_type': 'phone',
        'contact_value': '13800138000',
      };

      await repo.precheck(draft);

      final body = harness.server.lastRequest!.body as Map<String, Object?>;
      expect(body['type'], 'resource');
      expect(body['leaf_category_id'], 10101);
      expect(body['attributes'], {'headcount': '3'});
      expect(body['contact_value'], '13800138000');
    });
  });

  group('precheck 阻断（200 + code=0，链上不报错）', () {
    test('blocks 五码一次性给全，code/message/field 逐项解析', () async {
      stubPrecheck(harness, precheckBlockedPayload());

      final result = await repo.precheck(const {});

      expect(result.passed, isFalse);
      expect(result.blocks, hasLength(5));
      expect(result.blocks.map((b) => b.code), [40901, 40902, 40303, 40302, 40304]);
      // message 逐字取服务端值（契约「可直接呈现」），客户端不重写
      expect(result.blocks.first.message, '包含敏感词：xxx，请修改');
      // field 可选：40901 带、其余缺失为 null（两形态各覆盖）
      expect(result.blocks.first.field, 'title');
      expect(result.blocks[1].field, isNull);
      // 阻断态 completeness_level 缺失为 null（不猜默认值）
      expect(result.completenessLevel, isNull);
    });
  });

  group('precheck 链路错误（与「校验不通过」不同语义）', () {
    test('信封业务错误（40001）：DioException 包 ApiException 抛出',
        () async {
      harness.stub('POST', '/api/v1/posts/precheck', (req) async {
        return MockResponse(
          status: 400,
          body: ApiEnvelope.failure(40001, '参数缺失'),
        );
      });

      await expectLater(
        repo.precheck(const {}),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error 包业务异常',
            isA<ApiException>()
                .having((e) => e.code, 'code', ApiErrorCode.paramInvalid),
          ),
        ),
      );
    });

    test('required 字段缺失（blocks 非数组）：抛 parseError 不静默吞',
        () async {
      stubPrecheck(harness, {'passed': true, 'blocks': '不是数组'});

      await expectLater(
        repo.precheck(const {}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiErrorCode.parseError),
        ),
      );
    });
  });

  group('createPost 发布（[125] B5）', () {
    test('成功：回执 8 字段解析，请求带 Idempotency-Key（HeaderInterceptor'
        ' 写接口注入）', () async {
      stubCreatePost(harness);

      final created = await repo.createPost(const {});

      expect(created.id, 1001);
      expect(created.type, 'resource');
      expect(created.leafCategoryId, 40101);
      expect(created.l2CategoryId, 401); // 服务端派生回执
      expect(created.status, 'active');
      expect(created.version, 0);
      expect(created.completenessLevel, 1);
      // 幂等头由拦截器按写接口纪律注入（详设 §11.2），本层不碰
      expect(harness.server.lastRequest!.header('Idempotency-Key'), isNotNull,
          reason: 'POST /posts 是正式写接口，幂等键必须随请求发出');
    });

    test('载荷派生字段不传：l2_category_id/grid_id/expire_at/version 均缺',
        () async {
      stubCreatePost(harness);
      final draft = <String, Object?>{
        'type': 'resource',
        'leaf_category_id': 40101,
        'title': '九成新实木餐桌转让',
        'contact_type': 'phone',
        'contact_value': '13800138000',
      };

      await repo.createPost(draft);

      final body = harness.server.lastRequest!.body as Map<String, Object?>;
      for (final derived in [
        'l2_category_id',
        'grid_id',
        'expire_at',
        'version',
        'completeness_level',
      ]) {
        expect(body.containsKey(derived), isFalse,
            reason: '派生字段 $derived 由服务端生成，客户端传了也是坏先例');
      }
    });

    test('发布阻断五码（40901）：DioException 包 ApiException(sensitiveWord)',
        () async {
      stubCreatePostFailure(harness, 40901, '包含敏感词：xxx，请修改');

      await expectLater(
        repo.createPost(const {}),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error 包业务异常',
            isA<ApiException>()
                .having((e) => e.code, 'code', ApiErrorCode.sensitiveWord),
          ),
        ),
      );
    });

    test('响应缺 version：抛 parseError（出参必带 version 是契约红线）',
        () async {
      harness.stub('POST', '/api/v1/posts', (req) async {
        final payload = postCreatedPayload()..remove('version');
        return MockResponse(body: ApiEnvelope.success(data: payload));
      });

      await expectLater(
        repo.createPost(const {}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiErrorCode.parseError),
        ),
      );
    });
  });

  group('fetchDetail 详情（[127]）', () {
    test('成功：解析详情字段（price/author/attributes/时间）', () async {
      stubGetPostDetail(harness, 1001);

      final detail = await repo.fetchDetail(1001);

      expect(detail.id, 1001);
      expect(detail.type, 'resource');
      expect(detail.leafCategoryId, 40101);
      expect(detail.price, 299.0);
      expect(detail.priceUnit, '元');
      expect(detail.description, '九成新，无破损，可小刀');
      expect(detail.attributes, {'成色': '9 成新', '交易方式': '自提'});
      expect(detail.completenessLevel, 2);
      expect(detail.author.nickname, '王师傅');
      expect(detail.author.realnameStatus, 'passed');
      expect(detail.expireAt, DateTime.utc(2026, 9, 8, 4));
      expect(harness.server.received, hasLength(1));
    });

    test('price 缺失（面议）：解析为 null 不抛', () async {
      final payload = postDetailPayload()
        ..['price'] = null
        ..['price_unit'] = null;
      stubGetPostDetail(harness, 1001, payload: payload);

      final detail = await repo.fetchDetail(1001);

      expect(detail.price, isNull);
      expect(detail.priceUnit, isNull);
    });

    test('41001 已下架：DioException 包 ApiException(postGone)', () async {
      harness.stub('GET', '/api/v1/posts/1001', (req) async {
        return MockResponse(
          status: 410,
          body: ApiEnvelope.failure(41001, '该信息已下架或已过期'),
        );
      });

      await expectLater(
        repo.fetchDetail(1001),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error 包业务异常',
            isA<ApiException>()
                .having((e) => e.code, 'code', ApiErrorCode.postGone),
          ),
        ),
      );
    });
  });
}
