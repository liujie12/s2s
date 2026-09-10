/// 契约守门测试：OpenAPI 契约自身必须满足全局纪律。
///
/// 依据：docs/api/openapi.yaml 头部「全局纪律」与错误码表；
///       docs/PRD.md §12（接口需求）；《可观测性架构方案》§4（埋点）。
///
/// 这道门防的是「契约文档自己破坏自己定的规矩」——后端开工后，
/// 服务端代码以契约为准生成/校验，契约本身错了会把错误复制到所有实现里。
/// 在后端零代码阶段，契约是唯一可判的 API 面，故这道门现在就必须存在。
///
/// 判据全部为静态结构校验，不依赖任何运行中的服务，CI 可直接执行。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import '../support/test_support.dart';

/// 递归收集一个 YAML 节点下所有形如 `code: <int>` 的业务码。
///
/// 功能：复用响应的错误码藏在 examples.*.value.code 与 example.code 里，
/// 层级不固定，递归遍历最稳。
/// 参数：[node] 任意 YAML 节点；[sink] 收集结果的集合。
/// 返回：void，结果写入 [sink]。
void collectCodes(Object? node, Set<int> sink) {
  if (node is YamlMap) {
    final code = node['code'];
    if (code is int) sink.add(code);
    for (final v in node.nodes.entries) {
      collectCodes(v.value, sink);
    }
  } else if (node is YamlList) {
    for (final v in node) {
      collectCodes(v, sink);
    }
  }
}

void main() {
  // 契约在所有用例前加载一次；加载失败（文件缺失/YAML 语法错）直接让整组失败，
  // 不做 skip——契约文件缺失是「判据对象不存在」，跳过等于契约被删光时门禁全绿。
  late final OpenApiSpec spec;
  setUpAll(() {
    assertRepoLayout();
    spec = OpenApiSpec.load();
  });

  group('契约元信息', () {
    test('OpenAPI 版本为 3.0.x，契约版本非空', () {
      expect(spec.openapiVersion, startsWith('3.0'),
          reason: '全局纪律以 OpenAPI 3.0.3 为基线');
      expect(spec.infoVersion, isNotEmpty);
    });

    test('声明了本地与生产两个 server', () {
      final servers = (spec.raw['servers'] as YamlList?) ?? const [];
      expect(servers.length, greaterThanOrEqualTo(2),
          reason: '本地联调与生产基址都必须在契约中声明');
    });
  });

  group('错误码表：25 个业务码（成功 1 + 错误 24）', () {
    test('复用响应示例承载的业务码 = 24 个错误码减去后台专用 40305', () {
      final found = <int>{};
      collectCodes(spec.responses, found);
      expect(found.contains(0), isFalse,
          reason: '错误响应示例里不应出现 code=0');
      // 40305 是后台 RBAC 越权专用码，契约错误码表明确「App 端不返回」，
      // 故 App 端复用响应的 examples 刻意不承载它；它必须出现在 Forbidden
      // 的 description 文本中作为人工口径保留（见下一条断言）。
      final expectedInExamples =
          TestFixtures.allBusinessCodes.difference({0, 40305});
      expect(found, equals(expectedInExamples),
          reason: '口径源：openapi.yaml §3 错误码表。\n'
              '多了 = 契约示例写了错误码表未登记的码；少了 = 错误码表承诺的码没有任何响应承载。\n'
              '40305 为后台 RBAC 专用、App 端不返回，故不在示例集合内。');
    });

    test('后台专用码 40305 在 Forbidden 描述中显式声明「App 端不返回」', () {
      final forbidden = spec.responses?['Forbidden'];
      expect(forbidden, isNotNull);
      final desc = (forbidden!['description'] ?? '').toString();
      expect(desc, contains('40305'));
      expect(desc, contains('后台'),
          reason: '40305 必须标注为后台专用，防止 App 端实现误返回该码');
    });

    test('每个业务码前三位与其 HTTP 状态码对齐', () {
      TestFixtures.codeToHttpStatus.forEach((code, http) {
        expect(code ~/ 100, http,
            reason: '业务码 $code 应对齐 HTTP $http（code 前 3 位即 HTTP 码）');
      });
    });
  });

  group('全局纪律 4：写接口必带 Idempotency-Key', () {
    /// 判断操作是否为 Batch2/3 占位（未展开出入参）。
    ///
    /// 占位接口的 responses 形如 `{'200': {description: 占位...}}`，
    /// 不承载真实契约，故不参与「写接口必带幂等头」判定——
    /// 对未展开的接口要求参数声明，会把「还没写」误判为「写错了」。
    /// 判据：x-batch 非 Batch1 且 200 响应无 content（未展开响应体）。
    bool isPlaceholder(PathOperation op) {
      final batch = op.raw['x-batch']?.toString() ?? '';
      final ok = op.responses?['200'];
      final hasContent = ok is YamlMap && ok['content'] != null;
      return batch != 'Batch1' && !hasContent;
    }

    // 幂等头豁免登记：只允许「无写入副作用」的 POST 登记于此。
    // 豁免必须显式列名且附契约佐证——门禁四态原则：豁免不静默。
    // key 为 `METHOD path`，value 为契约中证明其不落库的佐证关键词。
    const idempotencyExempt = <String, String>{
      // 发布前置校验：契约明确「校验项与 POST /posts 一致但不写库」，
      // 纯只读校验，无重复写风险，幂等键无语义。
      'POST /posts/precheck': '不写库',
    };

    test('每个【有写入副作用】的已展开写接口都引用 IdempotencyKey 参数', () {
      final offenders = <String>[];
      final placeholders = <String>[];
      final exempted = <String>[];
      for (final op in spec.operations()) {
        if (!op.isWrite) continue;
        final key = '${op.method.toUpperCase()} ${op.path}';
        if (isPlaceholder(op)) {
          placeholders.add('$key(${op.raw['x-batch']} 占位)');
          continue;
        }
        if (idempotencyExempt.containsKey(key)) {
          // 豁免必须有契约文本佐证，防止把普通写接口误登记进豁免清单。
          final witness = idempotencyExempt[key]!;
          final desc = op.raw['description']?.toString() ?? '';
          expect(desc, contains(witness),
              reason: '$key 登记为幂等豁免，但契约描述中找不到佐证「$witness」。\n'
                  '豁免必须由契约文本证明其无写入副作用。');
          exempted.add('$key（佐证：$witness）');
          continue;
        }
        if (!op.referencesParameter('IdempotencyKey')) {
          offenders.add(key);
        }
      }
      // 占位与豁免接口都不静默：打印出来，让读测试输出的人知道它们被豁免了，
      // 而不是被漏检——豁免清单本身要可见（门禁四态：SKIP/豁免要列名）。
      // ignore: avoid_print
      print('  [INFO] 幂等头豁免（无写入副作用）：\n    ${exempted.join('\n    ')}');
      // ignore: avoid_print
      print('  [INFO] 以下写接口为后续批次占位，不参与判定：\n    ${placeholders.join('\n    ')}');
      expect(offenders, isEmpty,
          reason: '以下【已展开、有写入副作用】的写接口缺少 Idempotency-Key 声明：\n${offenders.join('\n')}\n'
              '契约纪律：所有写接口 24h 幂等，缺失会导致重复提交（网络重试/401 重放）产生重复数据。\n'
              '若无写入副作用（如纯校验），须在 idempotencyExempt 显式登记并附契约佐证。');
    });

    test('幂等键参数声明为 UUID v4 正则且 required', () {
      final idem = spec.parameters?['IdempotencyKey'] as YamlMap?;
      expect(idem, isNotNull, reason: 'components/parameters/IdempotencyKey 缺失');
      expect(idem!['required'], isTrue);
      final pattern =
          (idem['schema'] as YamlMap?)?['pattern']?.toString() ?? '';
      expect(pattern, contains('4[0-9a-f]{3}'),
          reason: '幂等键必须是 UUID v4（版本位 4）');
      expect(pattern, contains('[89ab]'),
          reason: '幂等键变体位必须符合 UUID v4 约束');
    });
  });

  group('全局纪律：Retry-After 强制响应头', () {
    test('TooManyRequests(429) 复用响应声明了 Retry-After 头', () {
      final tmr = spec.responses?['TooManyRequests'] as YamlMap?;
      expect(tmr, isNotNull);
      final headers = tmr!['headers'] as YamlMap?;
      expect(headers?['Retry-After'], isNotNull,
          reason: '42901–42907 必须回 Retry-After 剩余秒数');
    });

    test('Unauthorized(401) 复用响应声明了 Retry-After 头（40105 登录锁定）', () {
      final unauth = spec.responses?['Unauthorized'] as YamlMap?;
      final headers = unauth?['headers'] as YamlMap?;
      expect(headers?['Retry-After'], isNotNull,
          reason: '40105 锁定 15 分钟必须回 Retry-After');
    });

    test('Retry-After 定义为整数秒、最小值 1', () {
      final retryAfter =
          (spec.raw['components'] as YamlMap?)?['headers'] as YamlMap?;
      final def = retryAfter?['RetryAfter'] as YamlMap?;
      final schema = def?['schema'] as YamlMap?;
      expect(schema?['type'], 'integer');
      expect((schema?['minimum'] as int?) ?? 0, greaterThanOrEqualTo(1));
    });
  });

  group('全局纪律 1/2：统一响应包', () {
    test('ApiEnvelope 与 ApiError 模型均定义 code/message', () {
      final schemas = spec.schemas;
      final envelope = schemas?['ApiEnvelope'] as YamlMap?;
      final error = schemas?['ApiError'] as YamlMap?;
      expect(envelope, isNotNull, reason: '统一响应包骨架缺失');
      expect(error, isNotNull, reason: '失败响应模型缺失');
      for (final field in ['code', 'message']) {
        expect((envelope!['properties'] as YamlMap?)?.containsKey(field), isTrue,
            reason: 'ApiEnvelope 缺 $field');
        expect((error!['properties'] as YamlMap?)?.containsKey(field), isTrue,
            reason: 'ApiError 缺 $field');
      }
    });

    test('ApiError 的 data 字段声明为 nullable（失败时 data 恒为 null）', () {
      final error = spec.schemas?['ApiError'] as YamlMap?;
      final data = (error!['properties'] as YamlMap?)?['data'] as YamlMap?;
      expect(data?['nullable'], isTrue,
          reason: '失败响应 data 必须声明 nullable: true');
    });

    test('每个操作的响应键都是合法 HTTP 状态码', () {
      final validCodes = {'200', '201', '204', '400', '401', '403', '404', '409', '410', '429', '500', '503'};
      final bad = <String>[];
      for (final op in spec.operations()) {
        final responses = op.responses;
        if (responses == null) {
          bad.add('${op.method} ${op.path} 无 responses 段');
          continue;
        }
        for (final k in responses.keys) {
          if (!validCodes.contains(k.toString())) {
            bad.add('${op.method} ${op.path} 响应码 $k 不在契约允许集合内');
          }
        }
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
    });
  });

  group('全局纪律 5：时间与坐标格式', () {
    test('契约中 date-time 字段使用 RFC3339（format: date-time）', () {
      // expire_at / created_at 等时间字段应通过 format: date-time 声明。
      final formats = <String>[];
      void scanFormats(Object? node) {
        if (node is YamlMap) {
          if (node['format'] == 'date-time') formats.add(node.toString());
          for (final v in node.nodes.entries) {
            scanFormats(v.value);
          }
        } else if (node is YamlList) {
          for (final v in node) {
            scanFormats(v);
          }
        }
      }
      scanFormats(spec.schemas);
      expect(formats, isNotEmpty,
          reason: '契约中没有任何 date-time 字段，时间纪律（RFC3339 UTC）无承载');
    });
  });
}
