/// 联系域仓库（[128] 前端段；PRD §7.4.2 / §7.7 / §7.8；契约 §12.3
/// `GET /posts/{post_id}/contact` 与 `POST /posts/{post_id}/report`）。
///
/// **本文件是「完整联系方式」在客户端唯一的入口**。§14.3 规定全系统仅
/// `/contact` 一个接口返回完整值，§7.7 要求「完整号码不写入前端初始状态，
/// 通过点击时走 API 拉取」——因此 [FullContact] 只在内存里存活：
/// 不落盘、不进 Provider 缓存、不进埋点属性、不写日志（§9.6 数据最小化）。
/// 一旦缓存，「点击时才拉取」的防护就退化成「拉一次就永久持有」，
/// 而服务端限频只能限住请求次数，限不住已经到手的数据。
///
/// **失败必须建模成具名异常而不是返回 null**：null 只能表达「没拿到」，
/// 无法区分「今日超限」与「被熔断冻结」，而这两者给用户的文案与后续动作
/// 完全不同（§7.8 / §12.2）。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/contract_json.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../domain/listing_detail.dart';
import 'report_reason.dart';

/// 拉取完整联系方式失败的原因（对齐 §12.3 错误码）。
enum ContactFailure {
  /// 未登录（§7.7：仅登录用户可拉取完整号码）。
  ///
  /// 使代理池换 IP 无法绕过账号维度上限 —— 这是三维限频里唯一不可伪造的一维。
  notLoggedIn('请先登录后再查看联系方式'),

  /// 三维限频任一超限，对应 §12.3 错误码 `42902`。
  rateLimited('今日联系数已达上限，明天再来'),

  /// 熔断：单账号 1 分钟内 ≥10 次拉取，对应 §12.3 错误码 `42903`。
  ///
  /// 与 [rateLimited] 分开：前者是正常使用到量，后者是异常访问被冻结，
  /// 且后者会「进运营风控待审列表」。文案混用会让被误判的正常用户
  /// 以为只要等到明天就好，而实际上需要走申诉。
  circuitBroken('访问过于频繁，该功能已暂停至明日'),

  /// 帖子已下架或过期，对应 §12.3 错误码 `41001`。
  ///
  /// 与 [noContact] 分开：一个是「这条信息没了」，一个是「这条信息还在但
  /// 对方没留号码」——后者页面要引导用户举报让对方补充，前者该做的是离开。
  postGone('该信息已下架或已过期'),

  /// 对方未留联系方式（§7.8 边界）。
  noContact('对方未留联系方式，尝试举报让其补充'),

  /// 网络或服务端异常。
  networkError('网络异常，请稍后重试');

  const ContactFailure(this.message);

  /// 面向用户的提示文案。文案与原因绑在一起，避免同一错误在不同页面说法不一。
  final String message;
}

/// 拉取完整联系方式失败。
class ContactException implements Exception {
  /// 构造异常。
  ///
  /// 参数：[failure] 失败原因（决定页面文案与后续动作）。
  const ContactException(this.failure);

  /// 失败原因。
  final ContactFailure failure;

  @override
  String toString() => 'ContactException(${failure.name}): ${failure.message}';
}

/// 完整联系方式（仅存在于内存，用后即弃）。
class FullContact {
  /// 构造完整联系方式。
  ///
  /// 参数：
  ///   [channel]        联系方式渠道（决定按钮是拨号还是复制）；
  ///   [value]          完整联系方式明文；
  ///   [remainingToday] 服务端返回的今日剩余次数（**仅账号维度**，
  ///                    不是承诺值，见 [fetchFullContact] 的说明）。
  const FullContact({
    required this.channel,
    required this.value,
    required this.remainingToday,
  });

  /// 从契约响应 `data` 解析（字段：`contact_type` / `contact_value` /
  /// `remaining_today`，三者均 required）。
  ///
  /// 参数：[json] 信封 `data`（`GET /posts/{post_id}/contact` 的 data 字段）。
  /// 返回：[FullContact] 解析结果。
  /// 抛出：[ApiException]（`parseError`）—— 字段缺失、类型不符或
  ///   `contact_type` 出现契约外取值时，不返 null、不静默吞（§10.3）。
  factory FullContact.fromJson(Object? json) {
    final map = requireMap(json, 'ContactInfo');
    final type = requireString(map, 'contact_type', 'ContactInfo');
    final channel = switch (type) {
      'phone' => ContactChannel.phone,
      'wechat' => ContactChannel.wechat,
      // 契约外取值降级为 parseError，不猜成手机号（猜错会让按钮变成「拨打电话」，
      // 用户拨出去的却是个微信号）。
      _ => throw ApiException.parse('ContactInfo.contact_type 契约外取值: $type'),
    };
    return FullContact(
      channel: channel,
      value: requireString(map, 'contact_value', 'ContactInfo'),
      remainingToday: requireInt(map, 'remaining_today', 'ContactInfo'),
    );
  }

  /// 联系方式渠道。
  final ContactChannel channel;

  /// 完整联系方式明文。
  ///
  /// **不落盘、不进任何 Provider 缓存**：§9.6 数据最小化。一旦缓存，
  /// 「点击时才拉取」的防护就退化成「拉一次就永久持有」，
  /// 而限频只能限住请求次数，限不住已经拿到手的数据。
  final String value;

  /// 今日剩余可查看次数（**仅账号维度**）。
  ///
  /// 服务端限频有四个维度（账号 / 设备 / IP / 熔断），本字段只反映其中一个，
  /// 因此契约明令 UI **不得把它当承诺**：文案须写成「今日剩余 N 次（以实际请求
  /// 结果为准）」这样的带免责语的形态，禁用「还可查看 N 次」式承诺；
  /// 且收到 `42902` 后立即把本地显示的剩余刷成 0。
  final int remainingToday;

  /// 可拨号（仅手机号可拨）。
  bool get callable => channel == ContactChannel.phone;
}

/// 联系域仓库。
class ContactRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（测试经 NetworkChainHarness 注入，
  ///   生产经 [contactRepositoryProvider] 注入）。
  ContactRepository(this._dio);

  final Dio _dio;

  /// 拉取完整联系方式（`GET /posts/{post_id}/contact`，§12.3 全系统唯一出口）。
  ///
  /// 服务端五重防护（未登录 40101 / 账号 30 / 设备 30 / IP 100 / 熔断 42903），
  /// 任一不通过即失败，客户端把错误码翻成 [ContactFailure] 供页面呈现
  /// （文案与后续动作按 §12.2 行为表，不自动重试 429 类）。
  ///
  /// **成功即代表服务端已写两张表**（`contact_event` 北极星统计点 +
  /// `audit_log` 合规留痕，详设 §5.5.1）——客户端不需要、也无法补记。
  ///
  /// 参数：
  ///   [postId]        帖子 ID（契约路径参数 int64）；
  ///   [interactionId] 交互起点生成的 X-Interaction-Id（详设 §11.2 逐层透传）；
  ///                   null 时由 HeaderInterceptor 兜底生成。
  /// 返回：[FullContact] 完整联系方式 + 账号维剩余次数。
  /// 抛出：[ContactException] 携带 [ContactFailure]（含 `noContact`：调用方
  ///   在详情已知「对方未留联系方式」时本地短路，不发这次注定失败的请求）。
  Future<FullContact> fetchFullContact({
    required int postId,
    String? interactionId,
  }) async {
    try {
      final response = await _dio.get<Object?>(
        '/posts/$postId/contact',
        options: _interactionOptions(interactionId),
      );
      return FullContact.fromJson(response.data);
    } on ApiException catch (error) {
      // 解析失败（响应不符契约）也归到这里：页面只有「失败原因」一套文案位，
      // 契约不符在客户端没有独立处置动作（重试无用），且它属服务端与客户端的
      // 版本错配、由契约守门测试而非用户发现。落 networkError 是**有意的**折叠，
      // 不是漏处理 —— 见 [contactFailureOf] 的默认档。
      throw ContactException(contactFailureOf(error));
    } on DioException catch (error) {
      // 信封业务错误与传输错误两种形态统一经 asApiException 归一（§11.3 唯一拆包处）。
      throw ContactException(contactFailureOf(asApiException(error)));
    }
  }

  /// 提交举报（`POST /posts/{post_id}/report`，§12.3）。
  ///
  /// 举报频次异常时服务端回 `42903`（契约 §3.4 行 8），本层同样翻成
  /// [ContactFailure.circuitBroken] 由页面提示——举报与联系共用熔断语义，
  /// 但用的是两条独立的限频键。
  ///
  /// 幂等：契约挂 `Idempotency-Key`，HeaderInterceptor 按写接口（POST/PATCH）
  /// 纪律缺失即注入，本层不碰该头。
  ///
  /// 参数：
  ///   [postId]        被举报帖子 ID；
  ///   [reason]        举报原因（契约值取自 [ReportReason.apiValue]）；
  ///   [remark]        补充说明（可空，契约上限 200 字）；
  ///   [interactionId] 交互起点生成的 X-Interaction-Id；null 由拦截器兜底。
  /// 返回：`report_id`（服务端生成的举报记录 ID）。
  /// 抛出：[ContactException]（`postGone` 帖子不存在/不可见、`circuitBroken`
  ///   频次熔断、`notLoggedIn` 未登录、`networkError` 其余失败）。
  Future<int> submitReport(
    int postId, {
    required ReportReason reason,
    String? remark,
    String? interactionId,
  }) async {
    try {
      final response = await _dio.post<Object?>(
        '/posts/$postId/report',
        data: <String, Object?>{
          'reason': reason.apiValue,
          // remark 为空时整个键不传：契约 required 只有 reason，
          // 传空串会把「没填」变成「填了个空」。
          if (remark != null && remark.isNotEmpty) 'remark': remark,
        },
        options: _interactionOptions(interactionId),
      );
      final map = requireMap(response.data, 'ReportResult');
      return requireInt(map, 'report_id', 'ReportResult');
    } on ApiException catch (error) {
      throw ContactException(contactFailureOf(error));
    } on DioException catch (error) {
      throw ContactException(contactFailureOf(asApiException(error)));
    }
  }

  /// 组装携带 X-Interaction-Id 的按请求选项。
  ///
  /// 参数：[interactionId] 交互 ID，null 表示无透传值。
  /// 返回：[Options]；null（dio 接受 null options 走 BaseOptions 默认）。
  Options? _interactionOptions(String? interactionId) {
    if (interactionId == null) return null;
    return Options(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }
}

/// 把网络层错误码翻成联系页的失败原因（展示层映射的**唯一实现处**）。
///
/// 只映射本页面能给出有意义下一步的错误码；其余（含 40001、50001、
/// 传输层 `networkFailure`）统一落到 [ContactFailure.networkError]。
/// 不在这里实现重试策略——重试与续期的唯一决策处是拦截器链与
/// `ApiErrorCode.behavior`（编码规范 §1.2/§5.5）。
///
/// 参数：[exception] 链上归一后的统一异常。
/// 返回：[ContactFailure] 页面可直接取用的失败原因。
ContactFailure contactFailureOf(ApiException exception) {
  return switch (exception.code) {
    ApiErrorCode.unauthorized => ContactFailure.notLoggedIn,
    ApiErrorCode.contactLimit => ContactFailure.rateLimited,
    ApiErrorCode.circuitBroken => ContactFailure.circuitBroken,
    ApiErrorCode.postGone => ContactFailure.postGone,
    // 显式列出默认档：新增错误码时不会静默落进某个语义不符的分支
    // （§10.3 枚举显式 switch + default 降级）。
    _ => ContactFailure.networkError,
  };
}

/// 联系域仓库 Provider（dio 经 [dioProvider] 注入，与生产装配同源）。
final contactRepositoryProvider = Provider<ContactRepository>(
  (ref) => ContactRepository(ref.watch(dioProvider)),
);
