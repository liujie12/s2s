/// category 域仓库与契约 DTO 测试（[124] 前端段 / B1）。
///
/// 走 NetworkChainHarness 生产同款五拦截器链 + MockApiServer 真 HTTP 栈
/// （计划 R9）：不 mock repository 本身，后端就绪切 baseUrl 后断言
/// 一行不改。信封业务错误与 DTO 解析失败的**拆包形态不同**，用例分开
/// 断言：
///   - 信封业务错误（如 40001）：经 EnvelopeInterceptor reject，
///     调用方 catch 到 DioException（error 字段为 ApiException）；
///   - DTO 解析失败：fromJson 在响应返回后同步抛出，为裸 ApiException。
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/category/category_dto.dart';
import 'package:zhaoyazhao/features/category/category_repository.dart';

import '../../support/api_envelope.dart';
import '../../support/category_fixtures.dart';
import '../../support/mock_api_server.dart';
import '../../support/network_chain_harness.dart';

/// 登记 `/templates/{leaf_category_id}` 正常桩（两字段覆盖 number/select
/// 两类型与 required 两态）。
///
/// 参数：[harness] 网络链 harness。
/// 返回：void。
void _stubTemplate(NetworkChainHarness harness) {
  harness.stub('GET', '/api/v1/templates/10101', (req) async {
    return MockResponse(
      body: ApiEnvelope.success(
        data: {
          'leaf_category_id': 10101,
          'fields': [
            {
              'key': 'headcount',
              'label': '招聘人数',
              'type': 'number',
              'required': true,
              'placeholder': '如：3',
            },
            {
              'key': 'board',
              'label': '食宿情况',
              'type': 'select',
              'required': false,
              'options': ['包吃包住', '包吃不包住', '不包吃住'],
              'unit': null,
            },
          ],
        },
      ),
    );
  });
}

void main() {
  late NetworkChainHarness harness;
  late CategoryRepository repo;

  setUp(() async {
    harness = NetworkChainHarness();
    await harness.start();
    repo = CategoryRepository(harness.dio);
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('fetchTree 版本协商', () {
    test('不带 version（首启强制全量）：返回 full，请求不带 version 参数',
        () async {
      stubCategoryTree(harness);

      final result = await repo.fetchTree();

      expect(result.isUnchanged, isFalse);
      final tree = result.tree!;
      expect(tree.version, kServerTreeVersion);
      // 请求行不得携带 version 参数（契约：缺省即强制全量）。
      expect(
        Uri.parse(harness.server.lastRequest!.path).queryParameters,
        isNot(contains('version')),
      );
    });

    test('version 与服务端一致：返回 unchanged（304 语义 data=null）', () async {
      stubCategoryTree(harness);

      final result = await repo.fetchTree(localVersion: kServerTreeVersion);

      expect(result.isUnchanged, isTrue);
      expect(result.tree, isNull);
      // 确认确实发出去了协商请求（而非本地短路）。
      expect(
        Uri.parse(harness.server.lastRequest!.path).queryParameters['version'],
        kServerTreeVersion,
      );
    });

    test('version 落后于服务端：返回全量树，DTO 三级结构与可选标记齐全',
        () async {
      stubCategoryTree(harness);

      final result = await repo.fetchTree(localVersion: '2026-08-31.1');

      expect(result.isUnchanged, isFalse);
      final tree = result.tree!;
      expect(tree.version, kServerTreeVersion);
      expect(tree.categories, hasLength(1));

      final top = tree.categories.single;
      expect(top.id, 1);
      expect(top.level, 1);
      expect(top.children, hasLength(1));

      final mid = top.children!.single;
      expect(mid.id, 101);
      expect(mid.level, 2);
      expect(mid.children, hasLength(2));

      // 可选标记「出现」形态：逐字段对齐（icon 显式 JSON null → null）。
      final leaf = mid.children!.first;
      expect(leaf.id, 10101);
      expect(leaf.level, 3);
      expect(leaf.sensitive, isTrue);
      expect(leaf.banned, isFalse);
      expect(leaf.icon, isNull);
      expect(leaf.children, isNull); // L3 无 children

      // 可选标记「缺失」形态：不得被默认值掩盖，保持 null。
      final leaf2 = mid.children!.last;
      expect(leaf2.sensitive, isNull);
      expect(leaf2.banned, isNull);
      expect(leaf2.icon, isNull);
    });

    test('interactionId 透传：X-Interaction-Id 头逐字到达服务端', () async {
      stubCategoryTree(harness);
      const interactionId = '11111111-1111-4111-8111-111111111111';

      await repo.fetchTree(interactionId: interactionId);

      expect(
        harness.server.lastRequest!.header('x-interaction-id'),
        interactionId,
      );
    });
  });

  group('fetchTemplate', () {
    test('正常：字段模板逐字段解析（required 两态 + options/placeholder）',
        () async {
      _stubTemplate(harness);

      final template = await repo.fetchTemplate(10101);

      expect(template.leafCategoryId, 10101);
      expect(template.fields, hasLength(2));

      final number = template.fields[0];
      expect(number.key, 'headcount');
      expect(number.type, TemplateFieldTypeDto.number);
      expect(number.isRequired, isTrue);
      expect(number.placeholder, '如：3');
      expect(number.options, isNull);

      final select = template.fields[1];
      expect(select.key, 'board');
      expect(select.type, TemplateFieldTypeDto.select);
      expect(select.isRequired, isFalse);
      expect(select.options, ['包吃包住', '包吃不包住', '不包吃住']);
      expect(select.unit, isNull); // 显式 JSON null 与缺失同为 null
    });

    test('非法叶子 ID：服务端 40001 → DioException 包 ApiException'
        '（code=paramInvalid）', () async {
      harness.stub('GET', '/api/v1/templates/99999', (req) async {
        return MockResponse(
          status: 400,
          body: ApiEnvelope.failure(40001, '叶子类目不存在'),
        );
      });

      try {
        await repo.fetchTemplate(99999);
        fail('应抛 DioException（信封业务错误）');
      } on DioException catch (e) {
        expect(harness.apiErrorOf(e).code, ApiErrorCode.paramInvalid);
      }
    });

    test('type 未知值：降级 text 不抛错（default 降级，禁 values.byName 崩溃）',
        () async {
      harness.stub('GET', '/api/v1/templates/10101', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(
            data: {
              'leaf_category_id': 10101,
              'fields': [
                {
                  'key': 'future_field',
                  'label': '未来字段',
                  'type': 'future_type_2099',
                  'required': false,
                },
              ],
            },
          ),
        );
      });

      final template = await repo.fetchTemplate(10101);

      expect(template.fields.single.type, TemplateFieldTypeDto.text);
    });
  });

  group('DTO 解析失败（裸 ApiException，不经信封拆包）', () {
    test('required 字段缺失：抛 parseError，message 含键名与实际值', () {
      try {
        CategoryNodeDto.fromJson(const {'id': 10101, 'level': 3});
        fail('缺 name 应抛');
      } on ApiException catch (e) {
        expect(e.code, ApiErrorCode.parseError);
        expect(e.message, contains('name'));
      }
    });

    test('level 超出 1..3：抛 parseError（结构违约不可降级）', () {
      expect(
        () => CategoryNodeDto.fromJson(
          const {'id': 1, 'name': '工作', 'level': 4},
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.parseError,
          ),
        ),
      );
    });

    test('信封 data 非 Map：抛 parseError（含实际类型）', () {
      expect(
        () => CategoryTreeDto.fromJson('not-a-map'),
        throwsA(isA<ApiException>()),
      );
    });

    test('可选字段类型违约（sensitive 给字符串）：抛 parseError 不静默吞', () {
      expect(
        () => CategoryNodeDto.fromJson(
          const {'id': 1, 'name': 'x', 'level': 3, 'sensitive': 'yes'},
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('templateFieldTypeFromApi', () {
    test('契约五值逐一映射（显式 switch 全 case）', () {
      expect(templateFieldTypeFromApi('text'), TemplateFieldTypeDto.text);
      expect(templateFieldTypeFromApi('number'), TemplateFieldTypeDto.number);
      expect(templateFieldTypeFromApi('select'), TemplateFieldTypeDto.select);
      expect(
        templateFieldTypeFromApi('multi_select'),
        TemplateFieldTypeDto.multiSelect,
      );
      expect(templateFieldTypeFromApi('date'), TemplateFieldTypeDto.date);
    });

    test('未知值降级 text（default 分支）', () {
      expect(templateFieldTypeFromApi('richtext'), TemplateFieldTypeDto.text);
      expect(templateFieldTypeFromApi(''), TemplateFieldTypeDto.text);
    });
  });
}
