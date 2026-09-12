/// 测试脚手架统一出口（barrel）。
///
/// 用法：`import '../support/test_support.dart';`
///
/// 组成：
///   - repo_paths.dart     仓库路径解析与「待判对象存在」断言
///   - openapi_loader.dart OpenAPI 契约类型化加载
///   - api_envelope.dart   统一响应包构造与契约匹配器
///   - mock_api_server.dart 内存 Mock API 服务（真实 HTTP 栈）
///   - 本文件               契约测试通用 fixtures
library;

export 'api_envelope.dart';
export 'mock_api_server.dart';
export 'openapi_loader.dart';
export 'repo_paths.dart';

/// 契约测试通用固定值（fixtures）。
///
/// 集中放置的原因：UUID v4、RFC3339 时间、GCJ-02 坐标在契约里有
/// 格式纪律（幂等头正则、时间格式、坐标 5 位小数），各测试各拼一份
/// 容易拼出不符合纪律的值，导致断言测错东西。
class TestFixtures {
  const TestFixtures._();

  /// 合法的 Idempotency-Key（UUID v4，小写带连字符）。
  ///
  /// 符合契约 components/parameters/IdempotencyKey 的正则：
  /// `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`。
  static const String idempotencyKey = '9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d';

  /// 合法的 X-Interaction-Id。
  static const String interactionId = 'itx_1a2b3c4d5e6f';

  /// 合法的 X-Device-Id（UUID v4）。
  static const String deviceId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';

  /// UUID v4 形态正则（幂等键 / 交互 ID 兜底 / 设备 ID 共用唯一真源）。
  ///
  /// 形态口径同源契约 components/parameters/IdempotencyKey：
  /// `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`
  /// （小写、带连字符、版本位 4、变体位 8/9/a/b）。测试侧需要校验生成值
  /// 形态处一律引用本常量，禁止各抄一份正则字面量。
  static final RegExp uuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  /// 非法幂等键：大写 UUID（契约要求小写，服务端应回 40001）。
  static const String idempotencyKeyUppercase =
      '9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D';

  /// 非法幂等键：v1 UUID（版本位不是 4）。
  static const String idempotencyKeyV1 =
      '9b1deb4d-3b7d-1bad-9bdd-2b0d7b3dcb6d';

  /// RFC3339 UTC 样例时间。
  static const String rfc3339 = '2026-09-30T12:00:00Z';

  /// GCJ-02 样例坐标（杭州附近，5 位小数）。
  static const double latitude = 30.27415;
  static const double longitude = 120.15515;

  /// 契约 25 个业务码全集（成功码 1 + 错误码 24）。
  ///
  /// 口径源：docs/api/openapi.yaml 错误码表。硬编码而非解析 Markdown——
  /// 与 DevSecOps §5.1 RetentionRuleCoverageTest 同一选型：变更频率极低，
  /// 解析器自身会成为故障点；硬编码的代价（改契约要同步改测试）
  /// 正是这道门想要的效果。
  static const Set<int> allBusinessCodes = {
    0,
    40001, 40002,
    40101, 40105,
    40301, 40302, 40303, 40304, 40305,
    40901, 40902, 40903,
    41001,
    42901, 42902, 42903, 42904, 42905, 42906, 42907,
    50001,
    50301, 50302, 50303,
  };

  /// 必须携带 Retry-After 响应头的业务码（契约 §3 表 + RetryAfter 头定义）。
  static const Set<int> retryAfterCodes = {
    40105,
    42901, 42902, 42903, 42904, 42905, 42906, 42907,
  };

  /// 这些业务码归属的 HTTP 状态码（用于 code ↔ HTTP 对齐断言）。
  static const Map<int, int> codeToHttpStatus = {
    40001: 400, 40002: 400,
    40101: 401, 40105: 401,
    40301: 403, 40302: 403, 40303: 403, 40304: 403, 40305: 403,
    40901: 409, 40902: 409, 40903: 409,
    41001: 410,
    42901: 429, 42902: 429, 42903: 429, 42904: 429, 42905: 429,
    42906: 429, 42907: 429,
    50001: 500,
    50301: 503, 50302: 503, 50303: 503,
  };
}
