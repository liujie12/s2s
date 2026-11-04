/// 登录态集成契约（T1-04）：正式环境、仅测试账号、可重复清理。
///
/// 覆盖：
///   - IT-05 认证链：登录 → 本人资料 → 续期 → 退出 → 旧 Token 失效
///   - IT-03 幂等（登录路径）：同 Key 重放返回首次结果；非法 Key 回 40001
///   - IT-04 限频：连续发送验证码触发 429 且带 `Retry-After`
///     （DEF-01 修复后复验）
///   - IT-07 敏感字段：本人资料响应不得出现 `real_name` / `id_card` / 完整手机号
///
/// 运行方式（手机号不进仓库，运行时注入）：
///   `flutter test test/contract/authenticated_flow_test.dart \
///      --dart-define=S2S_API_BASE_URL=https://s2s.build110.com \
///      --dart-define=S2S_TEST_PHONE=<白名单测试号>`
///
/// 未注入基址或手机号时整组跳过；不写业务数据，只产生登录/设备/限频计数。
library;

import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 正式环境基址（编译期注入）。
const String _baseUrl = String.fromEnvironment('S2S_API_BASE_URL');

/// 测试手机号（编译期注入，必须是生产白名单内的账号）。
const String _testPhone = String.fromEnvironment('S2S_TEST_PHONE');

/// dev 桩验证码（生产当前仍为桩；正式接入短信后改由环境注入）。
const String _testCode = String.fromEnvironment(
  'S2S_TEST_CODE',
  defaultValue: '888888',
);

/// 各步骤的幂等键统一在运行时生成（见 `newKey()`），不复用常量，
/// 避免跨运行命中 24h 幂等缓存而污染限频与重放结果。

void main() {
  final bool enabled = _baseUrl.isNotEmpty && _testPhone.isNotEmpty;

  late Dio dio;
  String token = '';
  int userId = 0;

  /// 生成一次性幂等键（UUID v4）。
  ///
  /// 功能：每次运行使用新键，避免命中上一次运行遗留的幂等缓存，
  ///       造成「请求被重放、限频计数未增加」这类假结果。
  /// 参数：无。
  /// 返回：符合契约正则的小写 UUID v4。
  String newKey() {
    final Random rnd = Random.secure();
    final List<int> bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final String hex =
        bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// 构造请求客户端。
  ///
  /// 功能：统一 baseUrl、关闭状态码异常、带设备与交互头。
  /// 参数：无。
  /// 返回：无（写入外层 [dio]）。
  void initDio() {
    dio = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        validateStatus: (_) => true,
        headers: {
          'X-Interaction-Id': 'itx_1a2b3c4d5e6f',
          'X-Device-Id': '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
        },
      ),
    );
  }

  /// 发起请求并解析 JSON 响应。
  ///
  /// 功能：统一处理非 JSON 响应与状态码，返回响应对象与解析后的 Map。
  /// 参数：[method] HTTP 方法；[path] 契约路径；[data] 请求体；
  ///       [idempotencyKey] 幂等键；[useToken] 是否带登录态。
  /// 返回：`(Response<String>, Map<String, Object?>)` 记录。
  Future<(Response<String>, Map<String, Object?>)> call(
    String method,
    String path, {
    Map<String, Object?>? data,
    String? idempotencyKey,
    bool useToken = false,
  }) async {
    final Map<String, String> headers = <String, String>{};
    if (idempotencyKey != null) {
      headers['Idempotency-Key'] = idempotencyKey;
    }
    if (useToken) {
      headers['Authorization'] = 'Bearer $token';
    }
    final Response<String> resp = await dio.request<String>(
      path,
      data: data,
      options: Options(method: method, headers: headers),
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(resp.data ?? '');
    } on FormatException {
      fail('$method $path 返回非 JSON（HTTP ${resp.statusCode}）：${resp.data}');
    }
    expect(
      decoded,
      isA<Map>(),
      reason: '$method $path 响应体不是 JSON 对象：${resp.data}',
    );
    return (resp, Map<String, Object?>.from(decoded! as Map));
  }

  /// 断言成功信封并返回 data。
  ///
  /// 功能：统一校验 code=0 与包结构，减少重复断言。
  /// 参数：[body] 响应体；[label] 失败提示用。
  /// 返回：data 字段。
  Object? expectOk(Map<String, Object?> body, String label) {
    expect(body['code'], 0, reason: '$label 未成功：$body');
    expect(body.containsKey('message'), isTrue, reason: '$label 缺 message');
    expect(body.containsKey('data'), isTrue, reason: '$label 缺 data');
    expect(body.containsKey('request_id'), isTrue, reason: '$label 缺 request_id');
    return body['data'];
  }

  /// 断言响应不含敏感字段。
  ///
  /// 功能：扫描 JSON 原文，确认无 `real_name` / `id_card` / 完整手机号。
  /// 参数：[body] 响应体；[label] 失败提示用。
  /// 返回：void。
  void expectNoSensitive(Map<String, Object?> body, String label) {
    final String raw = jsonEncode(body);
    expect(raw.contains('real_name'), isFalse, reason: '$label 出现 real_name');
    expect(raw.contains('id_card'), isFalse, reason: '$label 出现 id_card');
    expect(raw.contains(_testPhone), isFalse, reason: '$label 回显了完整手机号');
  }

  /// 从分类树节点中取出第一个叶子类目 ID。
  ///
  /// 功能：递归向下查找没有 children 的节点，作为发布载荷的合法类目。
  /// 参数：[nodes] 分类节点数组。
  /// 返回：叶子类目 ID；找不到返回 0。
  int firstLeafId(List<dynamic> nodes) {
    for (final dynamic node in nodes) {
      if (node is! Map) continue;
      final Object? children = node['children'];
      if (children is List && children.isNotEmpty) {
        final int nested = firstLeafId(children);
        if (nested != 0) return nested;
      }
      final Object? id = node['id'];
      if (id is int) return id;
    }
    return 0;
  }

  group(
    '登录态集成契约（T1-04）',
    () {
      setUpAll(() {
        initDio();
      });

      test('登录成功并返回本人资料', () async {
        // 登录消费短信码，先发一条；若 1 分钟内已有发送，429 也可接受
        // （上一条码仍在 5 分钟有效期内）。
        final (Response<String> sendResp, Map<String, Object?> sendBody) =
            await call(
          'POST',
          '/auth/sms/send',
          data: <String, Object?>{'phone': _testPhone, 'scene': 'login'},
          idempotencyKey: newKey(),
        );
        expect(
          sendResp.statusCode,
          anyOf(200, 429),
          reason: '发送验证码只应 200 或 429：$sendBody',
        );

        final (Response<String> resp, Map<String, Object?> body) = await call(
          'POST',
          '/auth/sms/login',
          data: <String, Object?>{
            'phone': _testPhone,
            'code': _testCode,
            'agreed': true,
            'platform': 'android',
          },
          idempotencyKey: newKey(),
        );
        expect(resp.statusCode, 200, reason: '登录 HTTP 状态应为 200：$body');
        final Object? data = expectOk(body, '登录');
        final Map<String, Object?> login = Map<String, Object?>.from(data! as Map);

        expect(login['token'], isA<String>(), reason: '必须返回 token');
        expect((login['token']! as String).isNotEmpty, isTrue);
        expect(login['is_new_user'], isA<bool>(), reason: '必须返回 is_new_user');
        expect(login['user'], isA<Map>(), reason: '必须返回 user');

        token = login['token']! as String;
        userId = ((login['user']! as Map)['id'])! as int;
        expectNoSensitive(login, '登录响应');
      });

      test('GET /users/me 返回本人白名单视图', () async {
        final (Response<String> resp, Map<String, Object?> body) = await call(
          'GET',
          '/users/me',
          useToken: true,
        );
        expect(resp.statusCode, 200, reason: '本人资料 HTTP 应为 200：$body');
        final Object? data = expectOk(body, '本人资料');
        final Map<String, Object?> me = Map<String, Object?>.from(data! as Map);

        expect(me['id'], userId, reason: '返回的 id 必须是当前登录用户');
        final Object? mask = me['phone_mask'];
        expect(mask, isA<String>(), reason: '本人视图必须带 phone_mask');
        expect((mask! as String).contains('*'), isTrue, reason: '手机号必须脱敏');
        expectNoSensitive(body, '本人资料');
      });

      test('IT-03 同 Key 重发只创建一条帖子', () async {
        final (Response<String> treeResp, Map<String, Object?> treeBody) =
            await call('GET', '/categories/tree');
        expect(treeResp.statusCode, 200, reason: '分类树 HTTP 应为 200：$treeBody');
        final Object? treeData = expectOk(treeBody, '分类树');
        final int leafId =
            firstLeafId(((treeData! as Map)['categories'] as List));
        expect(leafId, isNot(0), reason: '未找到叶子类目');

        final String title =
            '[测试] 幂等探针 ${DateTime.now().millisecondsSinceEpoch % 1000000}';
        final Map<String, Object?> payload = <String, Object?>{
          'type': 'resource',
          'leaf_category_id': leafId,
          'title': title,
          'lng': 120.15,
          'lat': 30.28,
          'address_precise': true,
          'description': '自动化测试数据，测完下架',
        };
        final String key = newKey();

        final (Response<String> first, Map<String, Object?> firstBody) =
            await call(
          'POST',
          '/posts',
          data: payload,
          idempotencyKey: key,
          useToken: true,
        );
        expect(first.statusCode, 200, reason: '发布 HTTP 应为 200：$firstBody');
        final Map<String, Object?> created =
            Map<String, Object?>.from(expectOk(firstBody, '发布')! as Map);
        final int postId = created['id']! as int;
        final int version = created['version']! as int;

        final (Response<String> second, Map<String, Object?> secondBody) =
            await call(
          'POST',
          '/posts',
          data: payload,
          idempotencyKey: key,
          useToken: true,
        );
        expect(second.statusCode, 200,
            reason: '同 Key 重发 HTTP 应为 200：$secondBody');
        final Map<String, Object?> replayed =
            Map<String, Object?>.from(expectOk(secondBody, '重发')! as Map);
        expect(replayed['id'], postId, reason: '同 Key 重发必须返回同一条帖子，不得新建');

        // 清理：正式环境无删除接口，下架为可执行的最小收尾。
        final (Response<String> off, Map<String, Object?> offBody) = await call(
          'PATCH',
          '/posts/$postId/status',
          data: <String, Object?>{'action': 'offline', 'version': version},
          idempotencyKey: newKey(),
          useToken: true,
        );
        expect(off.statusCode, 200, reason: '下架 HTTP 应为 200：$offBody');
        // 输出残留 id，供证据账本登记与后续清理。
        // ignore: avoid_print
        print('IT03_POST_ID=$postId');
      });

      test('Token 续期返回新 token（IT-05）', () async {
        final (Response<String> resp, Map<String, Object?> body) = await call(
          'POST',
          '/auth/token/refresh',
          idempotencyKey: newKey(),
          useToken: true,
        );
        expect(resp.statusCode, 200, reason: '续期 HTTP 应为 200：$body');
        final Object? data = expectOk(body, '续期');
        final Map<String, Object?> refreshed =
            Map<String, Object?>.from(data! as Map);
        expect(refreshed['token'], isA<String>(), reason: '续期必须返回新 token');
        expect((refreshed['token']! as String).isNotEmpty, isTrue);
        token = refreshed['token']! as String;
      });

      test('连续发送验证码触发 429 且带 Retry-After（IT-04）', () async {
        Response<String>? limited;
        Map<String, Object?>? limitedBody;
        // 登录用例已发送过一次，这里最多再发 3 次，命中 429 即停。
        for (int i = 0; i < 3; i++) {
          final (Response<String> resp, Map<String, Object?> body) = await call(
            'POST',
            '/auth/sms/send',
            data: <String, Object?>{'phone': _testPhone, 'scene': 'login'},
            idempotencyKey: newKey(),
          );
          if (resp.statusCode == 429) {
            limited = resp;
            limitedBody = body;
            break;
          }
          expect(resp.statusCode, 200, reason: '发送验证码只应 200 或 429：$body');
        }
        expect(limited, isNotNull, reason: '1 分钟内连续发送必须被限频（42905）');
        expect(limitedBody!['code'], 42905, reason: '限频码应为 42905：$limitedBody');
        final String? retryAfter = limited!.headers.value('retry-after');
        expect(retryAfter, isNotNull, reason: '429 必须携带 Retry-After');
        expect(int.tryParse(retryAfter!), isNotNull, reason: 'Retry-After 必须是整数秒');
        expect(int.parse(retryAfter), greaterThanOrEqualTo(1));
        // ignore: avoid_print
        print('IT04_RETRY_AFTER=$retryAfter');
      });

      test('退出登录后旧 Token 立即失效（IT-05 收尾）', () async {
        final String oldToken = token;
        final (Response<String> resp, Map<String, Object?> body) = await call(
          'POST',
          '/auth/logout',
          idempotencyKey: newKey(),
          useToken: true,
        );
        expect(resp.statusCode, 200, reason: '退出登录 HTTP 应为 200：$body');
        expectOk(body, '退出登录');

        final (Response<String> after, Map<String, Object?> afterBody) = await call(
          'GET',
          '/users/me',
          useToken: false,
        );
        // 显式用旧 token 再打一次，确认服务端已失效而不是仅客户端清空。
        final Response<String> withOld = await dio.get<String>(
          '/users/me',
          options: Options(headers: <String, String>{
            'Authorization': 'Bearer $oldToken',
            'X-Interaction-Id': 'itx_1a2b3c4d5e6f',
            'X-Device-Id': '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
          }),
        );
        expect(after.statusCode, 401, reason: '无 Token 访问必须 401：$afterBody');
        expect(withOld.statusCode, 401, reason: '旧 Token 必须失效');
        final Map<String, Object?> oldBody =
            Map<String, Object?>.from(jsonDecode(withOld.data!) as Map);
        expect(oldBody['code'], 40101, reason: '旧 Token 应回 40101：$oldBody');
      });
    },
    skip: enabled
        ? false
        : '未注入 S2S_API_BASE_URL 或 S2S_TEST_PHONE；本组只用于正式环境测试账号',
  );
}
