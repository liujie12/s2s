/// 测试脚手架：OpenAPI 契约加载器。
///
/// 把 docs/api/openapi.yaml 解析为类型化视图，供两类测试复用：
///   1. 契约守门测试（test/gates/openapi_contract_gate_test.dart）——
///      校验契约自身是否满足全局纪律（错误码对齐、幂等头、Retry-After 等）；
///   2. 契约测试示范（test/contract/api_contract_example_test.dart）——
///      后端开工后，按 paths 逐个对真实服务做契约校验的样例。
///
/// 刻意不引入 openapi_spec 等重型库：本期校验项是有限的几条结构性规则，
/// 直接读 Map 即可；解析器自身会成为故障点（DevSecOps §5.1 的选型逻辑）。
library;

import 'package:yaml/yaml.dart';

import 'repo_paths.dart';

/// OpenAPI 契约的类型化只读视图。
class OpenApiSpec {
  const OpenApiSpec._(this.raw);

  /// 从仓库 docs/api/openapi.yaml 加载并解析契约。
  ///
  /// 返回：[OpenApiSpec] 解析后的契约视图；
  /// 抛出：[FormatException] 文件缺失或 YAML 语法错误时——
  /// 契约文件缺失属于「判据对象不存在」，调用方测试应直接 FAIL，
  /// 不得降级为跳过（否则契约被删光时门禁反而全绿）。
  static OpenApiSpec load() {
    if (!openapiSpecFile.existsSync()) {
      throw FormatException('OpenAPI 契约文件不存在：${openapiSpecFile.path}');
    }
    final text = openapiSpecFile.readAsStringSync();
    final doc = loadYaml(text);
    if (doc is! YamlMap) {
      throw const FormatException('OpenAPI 契约根节点不是映射结构');
    }
    return OpenApiSpec._(doc);
  }

  /// 原始 YAML 映射（只读）。
  final YamlMap raw;

  /// OpenAPI 版本声明，如 `3.0.3`。
  String get openapiVersion => raw['openapi'] as String? ?? '';

  /// 契约版本（info.version），如 `1.0.0-batch1`。
  String get infoVersion =>
      (raw['info'] as YamlMap?)?['version'] as String? ?? '';

  /// 全部路径条目。
  ///
  /// 返回：[Iterable] 形如 `(path: '/auth/login', ops: YamlMap{post: ...})`。
  Iterable<PathOperation> operations() sync* {
    final paths = raw['paths'] as YamlMap?;
    if (paths == null) return;
    for (final pathEntry in paths.nodes.entries) {
      // YamlMap 的键是 YamlScalar 而非 String，必须 toString()，
      // 直接 as String 会抛 YamlScalar subtype cast 错误。
      final path = pathEntry.key.toString();
      final ops = pathEntry.value as YamlMap?;
      if (ops == null) continue;
      for (final opEntry in ops.nodes.entries) {
        final method = opEntry.key.toString();
        if (!const {'get', 'post', 'put', 'patch', 'delete'}
            .contains(method)) {
          continue; // parameters / summary 等非操作键
        }
        yield PathOperation(
          path: path,
          method: method,
          raw: opEntry.value as YamlMap,
        );
      }
    }
  }

  /// components 参数表。
  YamlMap? get parameters =>
      (raw['components'] as YamlMap?)?['parameters'] as YamlMap?;

  /// components 复用响应表。
  YamlMap? get responses =>
      (raw['components'] as YamlMap?)?['responses'] as YamlMap?;

  /// components 数据模型表。
  YamlMap? get schemas =>
      (raw['components'] as YamlMap?)?['schemas'] as YamlMap?;
}

/// 单个接口操作（path + method + 定义体）。
class PathOperation {
  const PathOperation({
    required this.path,
    required this.method,
    required this.raw,
  });

  /// 接口路径，如 `/auth/login`。
  final String path;

  /// HTTP 方法小写，如 `post`。
  final String method;

  /// 操作定义原始映射。
  final YamlMap raw;

  /// 是否写接口（POST/PUT/PATCH/DELETE）。
  bool get isWrite =>
      const {'post', 'put', 'patch', 'delete'}.contains(method);

  /// 该操作声明的参数列表（原始映射序列）。
  List<YamlMap> get parameters {
    final params = raw['parameters'] as YamlList?;
    if (params == null) return const [];
    return params.whereType<YamlMap>().toList();
  }

  /// 响应表：HTTP 状态码字符串 → 响应定义映射。
  YamlMap? get responses => raw['responses'] as YamlMap?;

  /// 判断参数列表中是否引用了指定的 components 参数键。
  ///
  /// 参数：[paramKey] components/parameters 下的键名，如 `IdempotencyKey`。
  /// 返回：[bool] 存在 `$ref: '#/components/parameters/<paramKey>'` 则为 true。
  bool referencesParameter(String paramKey) {
    final needle = '#/components/parameters/$paramKey';
    return parameters.any((p) => p[r'$ref'] == needle);
  }
}

/// 解析操作级响应定义：`$ref` 到 components/responses 的取组件本体，
/// 内联定义的返回自身。
///
/// 与 [PathOperation.referencesParameter] 同层归拢（复审 #8）。
/// 链式 `$ref` 循环解析（复审 #2）：组件响应自身仍是 `$ref` 时逐层跟进，
/// 深度上限 8 防环；外部引用/错误前缀/查不到的组件键/超深一律返回
/// null——调用方不得静默 continue，必须把不可解析条目记入失败集合
/// （与 [OpenApiSpec.load]「判据对象不存在即失败」同口径）。
///
/// 参数：[node] 操作 responses 下的响应定义节点；
///       [components] components/responses 表（[OpenApiSpec.responses]）。
/// 返回：[YamlMap?] 解析后的响应定义；不可解析返回 null。
YamlMap? resolveResponse(Object? node, YamlMap? components) {
  var current = node;
  for (var depth = 0; depth < 8; depth++) {
    if (current is! YamlMap) return null;
    final ref = current[r'$ref']?.toString();
    if (ref == null) return current;
    const prefix = '#/components/responses/';
    if (!ref.startsWith(prefix)) return null;
    current = components?[ref.substring(prefix.length)];
  }
  return null; // 超深（疑似成环）视为不可解析
}
