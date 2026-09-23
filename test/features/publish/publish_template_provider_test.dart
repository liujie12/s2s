/// 发布模板装配 provider 测试（[124] 前端段 / B3）。
///
/// 走 NetworkChainHarness 生产同款五拦截器链 + MockApiServer 真 HTTP 栈：
/// 后端就绪切 baseUrl 后断言一行不改（[123] 已验证该模式）。本文件断言
/// B3 的三条装配纪律：
///   - 字段以服务端为真源（合成模板 extraFields 全部来自响应）；
///   - 框架文案（titlePlaceholder/priceUnits/descriptionGuide）恒取本地，
///     契约不下发这三项；
///   - 拉取失败降级本地模板（信封业务错误与传输侧错误两形态都降）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/domain/publish_template.dart';
import 'package:zhaoyazhao/features/publish/publish_template_provider.dart';

import '../../support/api_envelope.dart';
import '../../support/category_fixtures.dart';
import '../../support/mock_api_server.dart';
import '../../support/network_chain_harness.dart';

void main() {
  late NetworkChainHarness harness;
  late ProviderContainer container;

  setUp(() async {
    // 退避缝替换为即时完成：501 降级用例会走 networkFailure 自动重试，
    // 用真实退避（1s/2s）测试将等真实的秒级墙钟时间。
    harness = NetworkChainHarness(retrySleeper: (_) async {});
    await harness.start();
    container = ProviderContainer(
      overrides: [dioProvider.overrideWithValue(harness.dio)],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    await harness.dispose();
  });

  /// 读指定叶子的合成模板（family 键即叶子 ID）。
  ///
  /// 参数 [leafId] 叶子类目 ID。
  /// 返回：provider 产出的合成 [PublishTemplate]。
  Future<PublishTemplate> readTemplate(int leafId) {
    return container.read(publishTemplateProvider(leafId).future);
  }

  group('成功：服务端字段 + 本地框架文案合成', () {
    test('extraFields 全部来自服务端响应，框架文案恒取本地', () async {
      stubTemplate(harness); // 默认 10101：headcount 必填 number + board 选单

      final template = await readTemplate(10101);

      // 服务端字段（契约 TemplateField → 本地 spec 的映射逐项核对）
      expect(template.extraFields, hasLength(2));
      final headcount = template.extraFields[0];
      expect(headcount.key, 'headcount');
      expect(headcount.label, '招聘人数');
      expect(headcount.type, TemplateFieldType.number);
      expect(headcount.required, isTrue);
      expect(headcount.placeholder, '如：3');
      final board = template.extraFields[1];
      expect(board.type, TemplateFieldType.select);
      expect(board.required, isFalse);
      expect(board.options, ['包吃包住', '包吃不包住', '不包吃住']);

      // 框架文案契约没有，恒取本地 1.1 全职招聘模板
      final local = templateForLeaf(10101);
      expect(template.id, local.id);
      expect(template.titlePlaceholder, local.titlePlaceholder);
      expect(template.priceUnits, local.priceUnits);
      expect(template.descriptionGuide, local.descriptionGuide);
    });

    test('控件能力降级：multi_select → select、date → text（本地无对应控件）',
        () async {
      stubTemplate(
        harness,
        fields: [
          {
            'key': 'tags',
            'label': '标签',
            'type': 'multi_select',
            'required': false,
            'options': ['急招', '可兼职'],
          },
          {'key': 'start_date', 'label': '到岗日期', 'type': 'date',
              'required': true},
        ],
      );

      final template = await readTemplate(10101);

      expect(template.extraFields[0].type, TemplateFieldType.select);
      expect(template.extraFields[0].options, ['急招', '可兼职']);
      expect(template.extraFields[1].type, TemplateFieldType.text);
      expect(template.extraFields[1].required, isTrue);
    });

    test('通用模板叶子也能合并服务端字段（generic 文案保留）', () async {
      stubTemplate(
        harness,
        leafCategoryId: 40201,
        fields: [
          {'key': 'brand', 'label': '品牌', 'type': 'text', 'required': false},
        ],
      );

      final template = await readTemplate(40201);

      expect(template.isGeneric, isTrue);
      expect(template.titlePlaceholder, genericTemplate.titlePlaceholder);
      expect(template.extraFields.map((f) => f.key), ['brand']);
    });
  });

  group('失败：降级本地模板（发布链路不被模板接口单点拖死）', () {
    test('传输侧错误（501 非信封 → networkFailure 重试耗尽）降级本地字段',
        () async {
      // 不登记路由：mock 回 501 非信封纯文本 → 链尾归一 networkFailure
      final template = await readTemplate(10101);

      final local = templateForLeaf(10101);
      expect(template.id, local.id);
      expect(template.extraFields.map((f) => f.key),
          local.extraFields.map((f) => f.key));
      // networkFailure 行为 = autoRetry：总共 3 次请求（1 + 重试 2，退避缝
      // 已在 setUp 替换为即时）
      expect(harness.server.received, hasLength(3));
    });

    test('信封业务错误（40001 脏 ID，deterministicFail 不重试）降级本地模板',
        () async {
      harness.stub('GET', '/api/v1/templates/99999', (req) async {
        return MockResponse(
          status: 400,
          body: ApiEnvelope.failure(40001, '叶子类目不存在'),
        );
      });

      // 99999 本地也查不到模板 → 降级结果是通用模板
      final template = await readTemplate(99999);

      expect(template.isGeneric, isTrue);
      expect(template.extraFields, isEmpty);
      expect(harness.server.received, hasLength(1));
    });
  });

  group('family 缓存', () {
    test('同一容器内同叶子只拉取一次（再次进入发布页不重复请求）', () async {
      stubTemplate(harness);

      await readTemplate(10101);
      final second = await readTemplate(10101);

      expect(second.extraFields, hasLength(2));
      expect(harness.server.received, hasLength(1));
    });
  });
}
