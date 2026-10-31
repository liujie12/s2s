/// 详情页 / 中转页的「需申请」入口测试（计划 U14；R20 / R22 / R24 / R34）。
///
/// 只测纯映射与纯查找：页面上的点击编排依赖网络与路由，属真机走查项；
/// 这里钉死的是「契约字段有没有贯通到域模型」「已有会话能不能按帖子/ID 找到」
/// 「40305 在联系域翻成哪个失败原因」—— 这三处错位都不会抛异常，只会静默走错分支。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/contact/contact_repository.dart';
import 'package:zhaoyazhao/features/detail/post_detail_provider.dart';
import 'package:zhaoyazhao/features/message/conversation_entry.dart';
import 'package:zhaoyazhao/features/message/message_dto.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';

import '../../support/post_fixtures.dart';

void main() {
  /// 构造会话行。
  ///
  /// 参数：[conversationId] 会话 ID；[postId] 帖子 ID；[applyStatus] 申请卡状态。
  /// 返回：[ConversationDto]。
  ConversationDto conversation({
    required int conversationId,
    required int postId,
    String applyStatus = 'none',
  }) {
    return ConversationDto(
      conversationId: conversationId,
      postId: postId,
      postGone: false,
      peerId: 7,
      peerNickname: '王师傅',
      unread: false,
      applyStatus: applyStatus,
    );
  }

  group('契约字段贯通', () {
    test('PostDetail 缺 contact_apply_required → false（存量帖一键取号，R25）', () {
      final dto = PostDetailDto.fromJson(postDetailPayload());

      expect(dto.contactApplyRequired, isFalse);
    });

    test('PostDetail 带 contact_apply_required=true → 域模型同值', () {
      final payload = postDetailPayload()..['contact_apply_required'] = true;
      final dto = PostDetailDto.fromJson(payload);

      expect(dto.contactApplyRequired, isTrue);
      expect(
        postDetailToListingDetail(dto).contactApplyRequired,
        isTrue,
        reason: '详情页主按钮靠这个字段决定是否换成「申请查看联系方式」',
      );
    });
  });

  group('会话查找（入口三态的数据基础）', () {
    final items = [
      conversation(conversationId: 11, postId: 1001),
      conversation(conversationId: 12, postId: 1002, applyStatus: 'approved'),
    ];

    test('按帖子找到已有会话 → 入口显示「进入会话」', () {
      expect(conversationForPost(items, 1002)?.conversationId, 12);
    });

    test('帖子没有会话 → null（入口显示「发消息」）', () {
      expect(conversationForPost(items, 9999), isNull);
    });

    test('推送点击按会话 ID 找到行', () {
      expect(conversationById(items, 11)?.postId, 1001);
      expect(conversationById(items, 999), isNull);
    });

    test('同意态来自会话行的 apply_status', () {
      expect(conversationById(items, 12)?.applyStatus, 'approved');
    });
  });

  group('取号失败映射', () {
    test('40305 → 需申请闸门（不经网络错误兜底）', () {
      final failure = contactFailureOf(
        const ApiException(
          code: ApiErrorCode.noPermission,
          message: '请先申请并获发布者同意',
        ),
      );

      expect(failure, ContactFailure.applyRequired);
      expect(failure.message, isNotEmpty);
    });

    test('42902 仍是看号限额（会话额度不走这里）', () {
      final failure = contactFailureOf(
        const ApiException(
          code: ApiErrorCode.contactLimit,
          message: '今日联系数已达上限',
        ),
      );

      expect(failure, ContactFailure.rateLimited);
    });
  });
}
