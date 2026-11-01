/// 详情页 / 中转页 → 会话的入口编排（计划 U14；R20 / R24 / R34）。
///
/// 三态（R34）：
///   1. 未登录 → 先拉登录页，登录成功后继续这次点击（返回原页再进会话）；
///   2. 已有会话 → 直接进入，入口文案「进入会话」并带未读点；
///   3. 无会话 → 先开会话（`POST /conversations`，服务端按「帖子 + 发起人」复用），
///      再进入。
///
/// 申请意图（R20）：需申请帖在进入前调用 `POST /conversations/{id}/apply` 发出申请卡。
/// 冷却中 / 待审批 / 维护中都不阻断进入 —— 会话内的申请卡本身会显示真实状态与
/// 剩余天数（R21a），在这里弹错并拦下只会让用户连卡都看不到。
///
/// **42902 口径（R27）**：本链路只可能收到会话日额度（`POST /conversations`），
/// 它与 `GET /posts/{id}/contact` 的看号额度是两套计数。故本文件**不清零看号剩余
/// 次数**，只把服务端覆盖文案原样提示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../router/app_router.dart';
import '../auth/auth_repository.dart';
import 'message_dto.dart';
import 'message_list_provider.dart';
import 'message_repository.dart';

/// 在已加载的会话行里按帖子找会话。
///
/// 只查当前已加载的分页：列表尚未加载（如直接进详情页）或会话在更后面时返回
/// null，调用方改走 `POST /conversations` —— 服务端会复用既有会话、不消耗额度，
/// 因此「没找到」不会产生第二条会话（R5）。
///
/// 参数：[items] 已加载的会话行；[postId] 帖子 ID。
/// 返回：命中的会话行；无则 null。
ConversationDto? conversationForPost(
  Iterable<ConversationDto> items,
  int postId,
) {
  for (final item in items) {
    if (item.postId == postId) return item;
  }
  return null;
}

/// 在已加载的会话行里按会话 ID 找行（推送点击直达会话用，R16a）。
///
/// 参数：[items] 已加载的会话行；[conversationId] 会话 ID。
/// 返回：命中的会话行；无则 null（可能已隐藏或列表尚未加载）。
ConversationDto? conversationById(
  Iterable<ConversationDto> items,
  int conversationId,
) {
  for (final item in items) {
    if (item.conversationId == conversationId) return item;
  }
  return null;
}

/// 确保已登录；未登录时拉登录页，成功后返回 true。
///
/// 参数：[context] 构建上下文；[ref] Riverpod 句柄。
/// 返回：是否可继续本次动作（用户放弃登录时为 false）。
Future<bool> ensureLoggedIn(BuildContext context, WidgetRef ref) async {
  if (ref.read(isLoggedInProvider)) return true;
  final ok = await GoRouter.of(context).push<bool>(AppRoutes.login);
  return ok == true;
}

/// 从详情页 / 中转页进入会话（可携带申请意图）。
///
/// 参数：[context] 构建上下文；[ref] Riverpod 句柄；[postId] 帖子 ID；
///   [apply] true=同时发出联系方式申请卡（R20）。
/// 返回：[Future<void>]；用户取消登录或开会话失败时已就地提示，不抛异常。
Future<void> enterConversation(
  BuildContext context,
  WidgetRef ref, {
  required int postId,
  bool apply = false,
}) async {
  final existing = conversationForPost(
    ref.read(conversationsProvider).asData?.value.items ??
        const <ConversationDto>[],
    postId,
  );
  if (!await ensureLoggedIn(context, ref)) return;
  if (!context.mounted) return;

  var conversationId = existing?.conversationId;
  if (conversationId == null) {
    try {
      final result = await ref
          .read(messageRepositoryProvider)
          .openConversation(postId: postId);
      conversationId = result.conversationId;
      if (result.created) {
        // 新建才刷新列表：复用不改排序与未读，省一次请求。
        await ref.read(conversationsProvider.notifier).refresh();
      }
    } catch (e) {
      if (!context.mounted) return;
      // 41001 帖子不可见 / 40001 与自己开会话 / 42902 当日额度 /
      // 40305 维护中：服务端文案已覆盖到具体场景，原样展示（R27 / R30）。
      _toast(context, asApiException(e).uiMessage);
      return;
    }
  }

  if (apply) {
    try {
      await ref
          .read(messageRepositoryProvider)
          .applyContact(conversationId: conversationId);
      await ref.read(conversationsProvider.notifier).refresh();
    } catch (e) {
      // 冷却中 / 待审批不阻断进入：会话内的申请卡会显示真实状态；
      // 其余（维护只读等）提示一句后照常进入，历史消息仍可读（R30）。
      final error = asApiException(e);
      if (error.code != ApiErrorCode.paramInvalid && context.mounted) {
        _toast(context, error.uiMessage);
      }
    }
  }

  if (!context.mounted) return;
  // 详情页 / 中转页都在顶层路由：会话详情走**顶层** `/chat/:id`（设计与「不带
  // 底部导航」一致）。若直接 push 分支内的 `/messages/:id`，go_router 会再构造
  // 一套 shell，真机表现为「有底栏、内容全白」—— 2026-11-01 真机走查缺陷。
  context.push(
    '/chat/$conversationId',
    extra: existing,
  );
}

/// 弹一条轻提示。
///
/// 参数：[context] 构建上下文；[message] 文案。
/// 返回：void。
void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
