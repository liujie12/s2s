/// 联系中转页的数据层测试（PRD §7.4.2 / §7.7 / §7.8 / §12.3；[128] 接真服务）。
///
/// 走 NetworkChainHarness 生产同款五拦截器链 + MockApiServer 真 HTTP 栈
/// （后端就绪切 baseUrl 断言一行不改）。测四件「错了不会崩、但会直接伤到用户」的事：
/// 1. `hasContact` 判空 —— 判错的表现是按钮可点却拨出一个空号；
/// 2. 完整值只能来自服务端（客户端永不自造号码）；
/// 3. 失败原因彼此不混用 —— 限频与熔断文案混用会让被冻结的用户
///    以为等到明天就好，而实际上需要走申诉（§12.3 42902 / 42903）；
/// 4. 举报原因的「中文 ↔ 契约值」映射逐字对齐（错一个词服务端回 40001，
///    用户只看到「举报失败」）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/domain/listing.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/domain/listing_detail.dart';
import 'package:zhaoyazhao/features/contact/contact_repository.dart';
import 'package:zhaoyazhao/features/contact/report_reason.dart';

import 'support/api_envelope.dart';
import 'support/mock_api_server.dart';
import 'support/network_chain_harness.dart';
import 'support/repo_paths.dart';

final DateTime _now = DateTime(2026, 8, 28, 12);

ListingDetail _detail({
  ContactChannel channel = ContactChannel.phone,
  String? masked = '138****8000',
}) {
  return ListingDetail(
    listing: Listing(
      // id 为 int（详细设计 §10.4.3）。
      id: 1,
      title: '专业家庭日常保洁',
      category: ListingCategory.service,
      supplyDemand: SupplyDemand.supply,
      latitude: 30.0,
      longitude: 120.0,
      createdAt: _now,
    ),
    description: '描述',
    publisher: const Publisher(
      id: 'u1',
      nickname: '王师傅',
      realNameVerified: true,
    ),
    completeness: CompletenessLevel.green,
    expireAt: _now.add(const Duration(days: 7)),
    contactChannel: channel,
    contactMasked: masked,
    leafCategoryId: 50101, // 服务 > 家政/保洁 > 日常保洁
  );
}

/// 登记 `GET /posts/{id}/contact` 的成功响应。
///
/// 参数：
///   [harness]   链路 harness；
///   [channel]   契约 `contact_type`；
///   [value]     契约 `contact_value`；
///   [remaining] 契约 `remaining_today`。
/// 返回：void。
void stubContactSuccess(
  NetworkChainHarness harness, {
  String channel = 'phone',
  String value = '13800138000',
  int remaining = 27,
}) {
  harness.stub('GET', '/api/v1/posts/1/contact', (req) async {
    return MockResponse(
      status: 200,
      body: ApiEnvelope.success(
        data: {
          'contact_type': channel,
          'contact_value': value,
          'remaining_today': remaining,
        },
      ),
    );
  });
}

void main() {
  late NetworkChainHarness harness;
  late ContactRepository repo;

  setUp(() async {
    harness = NetworkChainHarness(retrySleeper: (_) async {});
    await harness.start();
    repo = ContactRepository(harness.dio);
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('hasContact（§7.8 对方联系方式未填边界）', () {
    test('填了联系方式为真', () {
      expect(_detail().hasContact, isTrue);
    });

    test('未填为假 —— 判错的表现是按钮可点但拨出空号', () {
      expect(_detail(masked: null).hasContact, isFalse);
    });
  });

  group('拉取完整联系方式（§12.3 GET /posts/{id}/contact）', () {
    test('成功：完整值只来自服务端，剩余次数逐字取服务端值', () async {
      stubContactSuccess(harness, value: '13800138000', remaining: 27);

      final full = await repo.fetchFullContact(postId: 1);

      expect(full.value, '13800138000');
      expect(full.channel, ContactChannel.phone);
      expect(full.callable, isTrue);
      // 剩余次数是服务端字段原值，客户端不做任何推算
      expect(full.remainingToday, 27);
      expect(harness.server.received, hasLength(1));
      expect(harness.server.lastRequest!.method, 'GET');
    });

    test('GET 不注入 Idempotency-Key —— 幂等键只给 POST/PATCH（§11.2）', () async {
      stubContactSuccess(harness);

      await repo.fetchFullContact(postId: 1);

      expect(harness.server.lastRequest!.header('idempotency-key'), isNull);
    });

    test('微信号渠道 callable 为假 —— 决定按钮是拨号还是复制', () async {
      stubContactSuccess(harness, channel: 'wechat', value: 'wx_happy12');

      final full = await repo.fetchFullContact(postId: 1);

      expect(full.channel, ContactChannel.wechat);
      expect(full.callable, isFalse);
    });

    test('42902 → rateLimited（不是 circuitBroken）', () async {
      harness.stubRateLimited('GET', '/api/v1/posts/1/contact', code: 42902);

      await expectLater(
        repo.fetchFullContact(postId: 1),
        throwsA(
          isA<ContactException>().having(
            (e) => e.failure,
            'failure',
            ContactFailure.rateLimited,
          ),
        ),
      );
    });

    test('42903 → circuitBroken（与限频文案必须分开）', () async {
      harness.stubRateLimited('GET', '/api/v1/posts/1/contact', code: 42903);

      await expectLater(
        repo.fetchFullContact(postId: 1),
        throwsA(
          isA<ContactException>().having(
            (e) => e.failure,
            'failure',
            ContactFailure.circuitBroken,
          ),
        ),
      );
    });

    test('40101 → notLoggedIn（页面据此给「去登录」入口）', () async {
      harness.stub('GET', '/api/v1/posts/1/contact', (req) async {
        return MockResponse(
          status: 401,
          body: ApiEnvelope.failure(40101, '登录已过期'),
        );
      });

      await expectLater(
        repo.fetchFullContact(postId: 1),
        throwsA(
          isA<ContactException>().having(
            (e) => e.failure,
            'failure',
            ContactFailure.notLoggedIn,
          ),
        ),
      );
    });

    test('41001 → postGone（与「对方未留联系方式」是两回事）', () async {
      harness.stub('GET', '/api/v1/posts/1/contact', (req) async {
        return MockResponse(
          status: 410,
          body: ApiEnvelope.failure(41001, '该信息已下架或已过期'),
        );
      });

      await expectLater(
        repo.fetchFullContact(postId: 1),
        throwsA(
          isA<ContactException>().having(
            (e) => e.failure,
            'failure',
            ContactFailure.postGone,
          ),
        ),
      );
    });

    test('contact_type 出现契约外取值 → 折叠为 networkError（不猜成手机号）',
        () async {
      stubContactSuccess(harness, channel: 'mail');

      await expectLater(
        repo.fetchFullContact(postId: 1),
        throwsA(
          isA<ContactException>().having(
            (e) => e.failure,
            'failure',
            ContactFailure.networkError,
          ),
        ),
      );
    });

    test('required 字段缺失 → 折叠为 networkError（不静默给空号码）', () async {
      harness.stub('GET', '/api/v1/posts/1/contact', (req) async {
        return MockResponse(
          status: 200,
          body: ApiEnvelope.success(data: {'contact_type': 'phone'}),
        );
      });

      await expectLater(
        repo.fetchFullContact(postId: 1),
        throwsA(isA<ContactException>()),
      );
    });
  });

  group('提交举报（§12.3 POST /posts/{id}/report）', () {
    test('成功：reason 发契约值，未填 remark 时整个键不传', () async {
      harness.stub('POST', '/api/v1/posts/1/report', (req) async {
        return MockResponse(
          status: 200,
          body: ApiEnvelope.success(data: {'report_id': 88, 'status': 'pending'}),
        );
      });

      final reportId = await repo.submitReport(
        1,
        reason: ReportReason.wrongCategory,
      );

      expect(reportId, 88);
      final body = harness.server.lastRequest!.body as Map<String, Object?>;
      expect(body['reason'], 'wrong_category');
      expect(body.containsKey('remark'), isFalse);
    });

    test('填了 remark 时原样透传', () async {
      harness.stub('POST', '/api/v1/posts/1/report', (req) async {
        return MockResponse(
          status: 200,
          body: ApiEnvelope.success(data: {'report_id': 89, 'status': 'pending'}),
        );
      });

      await repo.submitReport(1, reason: ReportReason.fraud, remark: '要求先付款');

      final body = harness.server.lastRequest!.body as Map<String, Object?>;
      expect(body['reason'], 'fraud');
      expect(body['remark'], '要求先付款');
    });

    test('42903 → circuitBroken（举报频次熔断与联系熔断文案一致）', () async {
      harness.stubRateLimited('POST', '/api/v1/posts/1/report', code: 42903);

      await expectLater(
        repo.submitReport(1, reason: ReportReason.other),
        throwsA(
          isA<ContactException>().having(
            (e) => e.failure,
            'failure',
            ContactFailure.circuitBroken,
          ),
        ),
      );
    });

    test('41001 → postGone（帖子已下架不可举报）', () async {
      harness.stub('POST', '/api/v1/posts/1/report', (req) async {
        return MockResponse(
          status: 410,
          body: ApiEnvelope.failure(41001, '该信息已下架或已过期'),
        );
      });

      await expectLater(
        repo.submitReport(1, reason: ReportReason.other),
        throwsA(
          isA<ContactException>().having(
            (e) => e.failure,
            'failure',
            ContactFailure.postGone,
          ),
        ),
      );
    });
  });

  group('失败原因文案（§12.3）', () {
    test('每种原因都有非空文案 —— 缺一条页面就会显示空白横幅', () {
      for (final f in ContactFailure.values) {
        expect(f.message, isNotEmpty, reason: '${f.name} 缺文案');
      }
    });

    test('限频与熔断文案不同 —— 混用会让被冻结的用户误以为等到明天就好', () {
      expect(
        ContactFailure.rateLimited.message,
        isNot(ContactFailure.circuitBroken.message),
      );
    });

    test('文案彼此不重复 —— 重复等于用户分不清自己遇到了哪种情况', () {
      final messages = ContactFailure.values.map((f) => f.message).toSet();
      expect(messages.length, ContactFailure.values.length);
    });

    test('剩余次数文案不承诺准确值（契约 remaining_today 原文纪律）', () {
      // 契约原文：文案须写「今日剩余 N 次（以实际请求结果为准）」，
      // **不得**用「今日还可查看 N 次」——后者在设备维/熔断维度先超限时
      // 会当场自我否定。此处做静态扫描，把这条文案纪律从「评审时记得看」
      // 变成「违反即红」（扫描的是全 lib/，防日后别的页面抄走错的那种写法）。
      final dartFiles = libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(
        dartFiles,
        isNotEmpty,
        reason: '扫描面为空 = 假阴性（部署 §14.5：不得在空扫描面上报通过）',
      );

      final offenders = <String>[];
      var disclaimerFound = false;
      for (final file in dartFiles) {
        final content = file.readAsStringSync();
        if (content.contains('今日还可查看')) offenders.add(file.path);
        if (content.contains('以实际请求结果为准')) disclaimerFound = true;
      }

      expect(
        offenders,
        isEmpty,
        reason: '契约禁止写「今日还可查看 N 次」（只反映账号维一个维度）',
      );
      expect(
        disclaimerFound,
        isTrue,
        reason: '页面必须带「以实际请求结果为准」的免责语',
      );
    });
  });

  group('举报原因映射（§7.7 五项，中文 ↔ 契约值）', () {
    test('五项齐全且顺序与 PRD §7.7 原文一致', () {
      expect(
        ReportReason.values.map((r) => r.label).toList(),
        ['不实信息', '诈骗', '违规类目', '骚扰', '其他'],
      );
    });

    test('契约值与 report.reason 列枚举逐字一致', () {
      expect(
        ReportReason.values.map((r) => r.apiValue).toList(),
        ['false_info', 'fraud', 'wrong_category', 'harassment', 'other'],
      );
    });
  });

  group('错误码 → 失败原因映射（唯一实现处）', () {
    test('未映射的码落 networkError 默认档（含 50001 与 parseError）', () {
      expect(
        contactFailureOf(
          const ApiException(code: ApiErrorCode.internalError, message: 'test'),
        ),
        ContactFailure.networkError,
      );
      expect(
        contactFailureOf(
          const ApiException(code: ApiErrorCode.parseError, message: 'test'),
        ),
        ContactFailure.networkError,
      );
    });
  });
}
