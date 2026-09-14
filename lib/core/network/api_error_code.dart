/// 客户端错误码枚举与行为映射（详细设计 §12.1 / §12.2），**唯一实现处**
/// （编码规范 §1.2）。
///
/// 与服务端 `ErrorCode` 枚举一一对应，唯一口径源同为 PRD §12.5（24 个错误码
/// + 成功码 `0`）；客户端本地码用负数，不占服务端码段 —— 服务端码段全是正数
/// 且前 3 位对齐 HTTP 状态码，负数永远不会与服务端新增码撞车（§12.1 注）。
///
/// [ApiErrorCode.behavior] 决定拿到这个码之后客户端做什么，是本枚举存在的
/// 主要价值 —— 没有它，每个 catch 点都会自己发明一套处理逻辑（§12.1 注）。
/// 映射一律查表驱动：禁止为个别码（如 `42906`）在消费侧写特例分支（计划 R4）。
///
/// **循环 import 说明**：本文件与 `api_exception.dart` 互相引用 ——
/// [ApiErrorCode.fromCode] 的未知码 default 降级按 §10.3 纪律抛
/// `ApiException(parseError)`，而 `ApiException.code` 字段类型回本枚举。
/// Dart 允许库间循环 import；两文件同目录、同属错误模型，不抽第三层。
library;

import 'api_exception.dart';

/// 拿到错误码后的客户端行为分类（§12.2 六类 + `ok` 的 [none]）。
///
/// §12.2 表共六行动作行为（架构 §6.6 的四分类 + `refreshToken` 单列 +
/// `ok` 不需要任何动作）。
enum ErrBehavior {
  /// 无动作：仅 `ApiErrorCode.ok` 持有，成功码不进任何错误处理分支。
  none,

  /// 按 §14 自动退避重试，**总共 2 次**（参数真源 `NfrNetwork`）；
  /// 仍失败则降级为确定性失败提示（§12.2）。
  autoRetry,

  /// **不自动重试**。弹提示并展示服务端 `Retry-After` 秒数换算的文案
  /// （如「请 58 秒后再试」），由用户显式点击重试（§12.2）。
  ///
  /// `42907` 例外之处：其提示除倒计时外**必须带登录入口**，因为登录就是
  /// 该限频的唯一解除方式（已登录不受此限，后端 §3.4）。
  promptWithRetryAfter,

  /// 埋点事件退回本地队列**头部**，按 `Retry-After` 延后。
  /// **全程不打扰用户**（§12.2）。仅 `42906` 持有。
  silentRequeue,

  /// 必须先 `GET /posts/{id}` 拿新 `version` 与新 `status`，用新状态刷新
  /// 界面，再由用户决定是否重新提交。**禁止自动带新 version 重发** ——
  /// 用户看到的状态可能已经变了（§12.2）。仅 `40903` 持有。
  forceRefetch,

  /// 展示 `message` + `request_id`，不重试（§12.2「其余全部」兜底桶）。
  deterministicFail,

  /// 走 §13 单飞续期，**不进入上述任何分支**（§12.2）。仅 `40101` 持有。
  refreshToken,
}

/// 客户端错误码枚举（§12.1 逐字落地：24 服务端码 + `ok` + 2 本地码）。
enum ApiErrorCode {
  /// 成功码。服务端失败响应 `data` 恒 null，`code=0` 时 `data` 可空
  /// （如 `GET /categories/tree` 版本相同，§11.3）。
  ok(0, ErrBehavior.none),

  // --- 4xx 确定性失败：提示用户，不重试 ---

  /// 参数非法。`PATCH /posts/{id}/status` 缺 `version` 也回本码，服务端
  /// 不兜底（§12.3：重试结果必然相同，不给重试按钮）。
  paramInvalid(40001, ErrBehavior.deterministicFail),

  /// 未同意隐私协议。
  agreementRequired(40002, ErrBehavior.deterministicFail),

  /// 未登录或 Token 失效。走 §13 单飞续期，不走本表其他分支（§12.1 注）。
  unauthorized(40101, ErrBehavior.refreshToken),

  /// 登录失败次数超限锁定。
  loginLocked(40105, ErrBehavior.promptWithRetryAfter),

  /// 详情浏览额度用尽。
  detailQuotaUsed(40301, ErrBehavior.deterministicFail),

  /// 需要资质认证。
  qualificationNeeded(40302, ErrBehavior.deterministicFail),

  /// 禁发类目。
  categoryBanned(40303, ErrBehavior.deterministicFail),

  /// 发布数量超限。
  publishLimit(40304, ErrBehavior.deterministicFail),

  /// 无权限。后台 RBAC 专用，App 端正常不应收到（§12.1 注）。
  noPermission(40305, ErrBehavior.deterministicFail),

  /// 命中敏感词。
  sensitiveWord(40901, ErrBehavior.deterministicFail),

  /// 图片审核驳回（仅本人可见）。
  imageRejected(40902, ErrBehavior.deterministicFail),

  /// 乐观锁版本冲突。唯一需要强制重取的码（§12.1 注）；
  /// 与 `40001` 的分支差异见 §12.3。
  versionConflict(40903, ErrBehavior.forceRefetch),

  /// 帖子已下架或删除。
  postGone(41001, ErrBehavior.deterministicFail),

  // --- 429 限流类：不可自动重试，展示剩余秒数 ---

  /// AI 配额超限。
  aiQuotaExceeded(42901, ErrBehavior.promptWithRetryAfter),

  /// 查看联系方式限频。
  contactLimit(42902, ErrBehavior.promptWithRetryAfter),

  /// 依赖服务熔断。
  circuitBroken(42903, ErrBehavior.promptWithRetryAfter),

  /// 推送限频。
  pushLimit(42904, ErrBehavior.promptWithRetryAfter),

  /// 短信限频。
  smsLimit(42905, ErrBehavior.promptWithRetryAfter),

  /// 埋点上报限频。唯一不向用户呈现的码（§12.1 注）。
  trackLimit(42906, ErrBehavior.silentRequeue),

  /// 游客详情浏览限频。提示须附登录入口（§12.1 注）；仅未登录请求生效。
  guestDetailLimit(42907, ErrBehavior.promptWithRetryAfter),

  // --- 5xx 可自动重试 ---

  /// 服务端内部错误。
  internalError(50001, ErrBehavior.autoRetry),

  /// AI 依赖不可用。
  aiUnavailable(50301, ErrBehavior.autoRetry),

  /// 实名认证依赖不可用。
  certUnavailable(50302, ErrBehavior.autoRetry),

  /// 地理服务依赖不可用。
  geoUnavailable(50303, ErrBehavior.autoRetry),

  // --- 客户端本地码（不来自服务端，不占服务端码段）---

  /// 网络失败：超时 / 连接失败（§12.1 注）。传输层归一点产出，
  /// 可重试语义与 5xx 一致。
  networkFailure(-1, ErrBehavior.autoRetry),

  /// 响应不符契约（§12.1 注）：字段缺失、类型不符、枚举出现契约外取值。
  /// 这类失败**不该重试** —— 服务端再发一次还是同样的响应体。
  parseError(-2, ErrBehavior.deterministicFail);

  const ApiErrorCode(this.code, this.behavior);

  /// 错误码数值。服务端码前 3 位对齐 HTTP 状态码（`code ~/ 100`），
  /// 本地码为负数（-1/-2）。
  final int code;

  /// 该码对应的客户端行为（§12.2 查表唯一入口）。
  final ErrBehavior behavior;

  /// 按码值查枚举。
  ///
  /// 遍历 `values` 而非 27 行 `switch`：枚举自身即码值真源，switch 会把
  /// 全部码字面量复制第二份，违反「不复制字面量」硬纪律（详设 §0.1）；
  /// 查表只发生在错误路径，O(n) 代价可忽略。
  ///
  /// [code] 服务端信封 `code` 字段或本地归一码。
  /// 返回：码值对应的枚举实例。
  /// 抛出：[ApiException]（`parseError`）—— 契约外码值（§10.3 default
  /// 降级：不返 null、不静默吞，message 含实际收到的码值）。
  static ApiErrorCode fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    throw ApiException.parse('未知错误码: $code');
  }
}
