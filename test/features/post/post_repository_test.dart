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
}
