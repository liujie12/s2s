/// chat 域仓库测试（计划 U11）。
///
/// 走 NetworkChainHarness 生产同款五拦截器链 + MockApiServer 真 HTTP 栈；
/// 断言：请求体/幂等头、DTO 解析（含可空字段）、服务端错误映射为既有异常、
/// 契约字段缺失按解析失败处理（不静默兜底）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/message/message_repository.dart';

import '../../support/api_envelope.dart';
import '../../support/mock_api_server.dart';
import '../../support/network_chain_harness.dart';

void main() {
  late NetworkChainHarness harness;
  late MessageRepository repo;

  setUp(() async {
    harness = NetworkChainHarness(retrySleeper: (_) async {});
    await harness.start();
    repo = MessageRepository(harness.dio);
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('openConversation', () {
    test('请求体只带 post_id，解析 conversation_id/created', () async {
      late Map<String, Object?> sentBody;
      harness.stub('POST', '/api/v1/conversations', (req) async {
        sentBody = (req.body as Map).cast<String, Object?>();
        return MockResponse(
          body: ApiEnvelope.success(
            data: {'conversation_id': 88, 'created': true},
          ),
        );
      });

      final result = await repo.openConversation(postId: 42);

      expect(sentBody, {'post_id': 42});
      expect(result.conversationId, 88);
      expect(result.created, isTrue);
    });

    test('42902 抛既有异常且保留服务端专用文案', () async {
      harness.stub('POST', '/api/v1/conversations', (req) async {
        return MockResponse(
          status: 429,
          headers: const {'Retry-After': '3600'},
          body: ApiEnvelope.failure(42902, '今日发起会话数已达上限'),
        );
      });

      try {
        await repo.openConversation(postId: 42);
        fail('应抛出 42902');
      } catch (e) {
        final error = harness.apiErrorOf(e);
        expect(error.code, ApiErrorCode.contactLimit);
        expect(error.message, '今日发起会话数已达上限');
        expect(error.retryAfterSec, 3600);
      }
    });
  });

  group('fetchConversations', () {
    test('解析可空字段与未读布尔', () async {
      harness.stub('GET', '/api/v1/conversations', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(data: {
            'items': [
              {
                'conversation_id': 1,
                'post_id': 2,
                'post_title': '静安两居',
                'post_thumbnail_url': 'https://oss/display/1.jpg',
                'post_gone': false,
                'peer_id': 3,
                'peer_nickname': '王师傅',
                'peer_avatar_url': null,
                'last_message_type': 'text',
                'last_message_preview': '可以的，我下午三点前都在',
                'last_message_at': '2026-10-31T09:04:00Z',
                'unread': true,
                'apply_status': 'none',
              },
            ],
            'total': 1,
            'page': 1,
            'page_size': 20,
          }),
        );
      });

      final page = await repo.fetchConversations();

      expect(page.total, 1);
      expect(page.pageSize, 20);
      final item = page.items.single;
      expect(item.conversationId, 1);
      expect(item.peerNickname, '王师傅');
      expect(item.unread, isTrue);
      expect(item.postGone, isFalse);
      expect(item.applyStatus, 'none');
      expect(item.postThumbnailUrl, 'https://oss/display/1.jpg');
      expect(item.peerAvatarUrl, isNull);
      expect(item.lastMessageAt, DateTime.utc(2026, 10, 31, 9, 4));
    });

    test('required 字段缺失按解析失败抛 ApiException.parse', () async {
      harness.stub('GET', '/api/v1/conversations', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(data: {
            'items': [
              {'conversation_id': 1},
            ],
            'total': 1,
            'page': 1,
            'page_size': 20,
          }),
        );
      });

      await expectLater(
        repo.fetchConversations(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.parseError,
          ),
        ),
      );
    });
  });

  group('fetchMessages', () {
    test('items 按 seq 正序解析，游标按传入组装', () async {
      harness.stub(
        'GET',
        '/api/v1/conversations/7/messages',
        (req) async => MockResponse(
          body: ApiEnvelope.success(data: {
            'items': [
              {
                'message_id': 10,
                'seq': 1,
                'sender_id': 3,
                'type': 'text',
                'content': '你好',
                'created_at': '2026-10-31T09:00:00Z',
              },
              {
                'message_id': 11,
                'seq': 2,
                'sender_id': 4,
                'type': 'contact',
                'content': null,
                'created_at': '2026-10-31T09:01:00Z',
              },
            ],
            'has_more': false,
            'peer_last_read_seq': 2,
          }),
        ),
      );

      final page = await repo.fetchMessages(conversationId: 7, afterSeq: 0);

      expect(page.items.map((m) => m.seq), [1, 2]);
      expect(page.items.first.content, '你好');
      expect(page.items.last.type, 'contact');
      expect(page.items.last.content, isNull);
      expect(page.hasMore, isFalse);
      expect(page.peerLastReadSeq, 2);
    });

    test('40305 非成员复用「不存在」文案', () async {
      harness.stub('GET', '/api/v1/conversations/7/messages', (req) async {
        return MockResponse(
          status: 403,
          body: ApiEnvelope.failure(40305, '会话不存在或已不可访问'),
        );
      });

      try {
        await repo.fetchMessages(conversationId: 7);
        fail('应抛出 40305');
      } catch (e) {
        final error = harness.apiErrorOf(e);
        expect(error.code, ApiErrorCode.noPermission);
        expect(error.message, '会话不存在或已不可访问');
      }
    });
  });

  group('sendMessage', () {
    test('正文透传，重发沿用传入的幂等键', () async {
      late Map<String, Object?> sentBody;
      late Map<String, String> sentHeaders;
      harness.stub('POST', '/api/v1/conversations/7/messages', (req) async {
        sentBody = (req.body as Map).cast<String, Object?>();
        sentHeaders = req.headers;
        return MockResponse(
          body: ApiEnvelope.success(data: {
            'message_id': 12,
            'conversation_id': 7,
            'seq': 3,
            'created_at': '2026-10-31T09:02:00Z',
          }),
        );
      });

      final result = await repo.sendMessage(
        conversationId: 7,
        content: '下午三点可以吗',
        idempotencyKey: 'key-resend-1',
      );

      expect(sentBody, {'content': '下午三点可以吗'});
      expect(
        sentHeaders[HeaderInterceptor.idempotencyKeyHeader.toLowerCase()],
        'key-resend-1',
      );
      expect(result.messageId, 12);
      expect(result.seq, 3);
      expect(result.conversationId, 7);
    });

    test('未传幂等键时由拦截器注入（不是空头）', () async {
      late Map<String, String> sentHeaders;
      harness.stub('POST', '/api/v1/conversations/7/messages', (req) async {
        sentHeaders = req.headers;
        return MockResponse(
          body: ApiEnvelope.success(data: {
            'message_id': 13,
            'conversation_id': 7,
            'seq': 4,
            'created_at': '2026-10-31T09:03:00Z',
          }),
        );
      });

      await repo.sendMessage(conversationId: 7, content: '在吗');

      final key =
          sentHeaders[HeaderInterceptor.idempotencyKeyHeader.toLowerCase()];
      expect(key, isNotNull);
      expect(key, isNotEmpty);
      expect(harness.uuidCallCount, greaterThanOrEqualTo(1));
    });

    test('40901 敏感词拒发抛既有异常', () async {
      harness.stub('POST', '/api/v1/conversations/7/messages', (req) async {
        return MockResponse(
          status: 409,
          body: ApiEnvelope.failure(40901, '内容包含敏感词，请修改后重试'),
        );
      });

      try {
        await repo.sendMessage(conversationId: 7, content: 'xx');
        fail('应抛出 40901');
      } catch (e) {
        final error = harness.apiErrorOf(e);
        expect(error.code, ApiErrorCode.sensitiveWord);
        expect(error.message, '内容包含敏感词，请修改后重试');
      }
    });
  });

  group('markRead 与未读汇总', () {
    test('置已读返回推进后的水位', () async {
      harness.stub('POST', '/api/v1/conversations/7/read', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(data: {'last_read_seq': 9}),
        );
      });

      final result = await repo.markRead(conversationId: 7);

      expect(result.lastReadSeq, 9);
    });

    test('未读汇总逐字段解析（客户端不做二次求和）', () async {
      harness.stub('GET', '/api/v1/unread-summary', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(data: {
            'total': 12,
            'conversation_unread': 10,
            'notification_unread': 2,
          }),
        );
      });

      final summary = await repo.fetchUnreadSummary();

      expect(summary.total, 12);
      expect(summary.conversationUnread, 10);
      expect(summary.notificationUnread, 2);
    });
  });

  group('申请卡与举报', () {
    test('审批载荷为 approved 布尔，返回卡片状态', () async {
      late Map<String, Object?> sentBody;
      harness.stub(
        'POST',
        '/api/v1/conversations/7/apply/decision',
        (req) async {
          sentBody = (req.body as Map).cast<String, Object?>();
          return MockResponse(
            body: ApiEnvelope.success(data: {
              'conversation_id': 7,
              'apply_required': true,
              'apply_status': 'approved',
              'owner': false,
              'can_apply': false,
              'can_view_contact': true,
              'reapply_at': null,
            }),
          );
        },
      );

      final state = await repo.decideApply(conversationId: 7, approved: true);

      expect(sentBody, {'approved': true});
      expect(state.applyStatus, 'approved');
      expect(state.canViewContact, isTrue);
      expect(state.owner, isFalse);
      expect(state.reapplyAt, isNull);
    });

    test('误拦反馈带 misblock 与原文，落到同一举报入口', () async {
      late Map<String, Object?> sentBody;
      harness.stub('POST', '/api/v1/conversations/7/report', (req) async {
        sentBody = (req.body as Map).cast<String, Object?>();
        return MockResponse(
          body: ApiEnvelope.success(
            data: {'report_id': 55, 'status': 'pending'},
          ),
        );
      });

      final result = await repo.reportConversation(
        conversationId: 7,
        reason: 'misblock',
        blockedText: '这是我的联系方式上下文',
      );

      expect(sentBody['reason'], 'misblock');
      expect(sentBody['blocked_text'], '这是我的联系方式上下文');
      expect(sentBody.containsKey('remark'), isFalse);
      expect(result.reportId, 55);
      expect(result.status, 'pending');
    });
  });
}
