/// 测试脚手架：统一响应包构造与契约匹配器。
///
/// 对应契约全局纪律第 1/2/3 条：
///   任何 HTTP 状态码下响应体均为 `{code, message, data, request_id}`；
///   code=0 成功；非 0 时 data 为 null；request_id 服务端生成
///   （缓存命中时可不存在）。
///
/// 后端开工后，契约测试对真实/mock 服务发请求，用这里的匹配器断言
/// 响应包形态——避免每个测试各写一套字段检查、漏判「data 失败时未置 null」
/// 这类静默缺陷。
library;

// Matcher/predicate 经 flutter_test 转出（脚手架只依赖已声明的 flutter_test，
// 不直接依赖 package:test，避免 depend_on_referenced_packages）。
import 'package:flutter_test/flutter_test.dart' show Matcher, predicate;

/// 统一响应包构造工具。
class ApiEnvelope {
  const ApiEnvelope._();

  /// 构造一个成功响应包。
  ///
  /// 参数：
  ///   [data]       业务负载（任意 JSON 可序列化结构）；
  ///   [requestId]  请求标识，默认给一个形如 `req_test_*` 的测试值；
  ///   [message]    文案，默认 `ok`。
  /// 返回：[Map] 完整响应包，可直接作为 mock 响应体。
  static Map<String, Object?> success({
    Object? data,
    String requestId = 'req_test_success',
    String message = 'ok',
  }) {
    return {
      'code': 0,
      'message': message,
      'data': data,
      'request_id': requestId,
    };
  }

  /// 构造一个失败响应包。
  ///
  /// 契约纪律：失败时 `data` 恒为 null、message 为可直接呈现的中文文案。
  ///
  /// 参数：
  ///   [code]       业务错误码（非 0，如 40001）；
  ///   [message]    用户可见中文文案；
  ///   [requestId]  请求标识。
  /// 返回：[Map] 失败响应包；[data] 固定为 null。
  static Map<String, Object?> failure(
    int code,
    String message, {
    String requestId = 'req_test_failure',
  }) {
    return {
      'code': code,
      'message': message,
      'data': null,
      'request_id': requestId,
    };
  }
}

/// 匹配器：成功响应包（code=0 且包含包结构四字段）。
///
/// 不强制 data 非 null——部分成功接口 data 本身为 null（如 logout）。
///
/// 用法：`expect(responseBody, isSuccessEnvelope);`
final Matcher isSuccessEnvelope = predicate<Object?>(
  (obj) =>
      obj is Map &&
      obj['code'] == 0 &&
      obj.containsKey('message') &&
      obj.containsKey('data') &&
      obj.containsKey('request_id'),
  '是 code=0 的统一响应包（含 message/data/request_id）',
);

/// 匹配器：失败响应包。
///
/// 校验三件契约强约束：code 非 0、data 恒为 null、message 为非空字符串。
///
/// 参数：[expectedCode] 期望的业务错误码；为 null 时只校验「非 0」。
/// 返回：[Matcher] 供 expect 使用。
Matcher isFailureEnvelope([int? expectedCode]) {
  return predicate<Object?>(
    (obj) =>
        obj is Map &&
        obj['code'] is int &&
        obj['code'] != 0 &&
        (expectedCode == null || obj['code'] == expectedCode) &&
        obj['data'] == null &&
        obj['message'] is String &&
        (obj['message'] as String).isNotEmpty,
    expectedCode == null
        ? '是失败响应包（code 非 0、data=null、message 非空）'
        : '是 code=$expectedCode 的失败响应包（data=null、message 非空）',
  );
}

/// 匹配器：业务码前三位与 HTTP 状态码对齐（契约错误码表纪律）。
///
/// 业务码 5 位，前 3 位即 HTTP 状态码：42902 ~/ 100 == 429、50301 ~/ 100 == 503。
///
/// 参数：[httpStatus] HTTP 状态码（如 429）。
/// 返回：[Matcher] 校验 `body.code ~/ 100 == httpStatus`。
Matcher hasCodeAlignedWithHttp(int httpStatus) {
  return predicate<Object?>(
    (obj) =>
        obj is Map &&
        obj['code'] is int &&
        (obj['code'] as int) ~/ 100 == httpStatus,
    '响应包 code 前三位与 HTTP $httpStatus 对齐',
  );
}
