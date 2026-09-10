package com.s2s.server.common.error;

/**
 * 全系统错误码枚举（24 业务码 + {@code OK(0)} = 25 枚）。唯一口径源为 PRD §12.5。
 *
 * <p>分段规则：前 3 位与 HTTP 状态码对齐（40xxx→400，42xxx→429，50xxx→500 等），
 * {@code OK(0,200)} 为 {@code code/100==httpStatus} 规则的豁免项（R-4 明列）。
 * 新增枚举值前必须先确认该 code 未被占用——代码侧禁止占号，新增只能由需求侧在 PRD 定案
 * （详设 §2.3；编码规范 §0.2「不新增错误码」）。
 *
 * <p>{@code needRetryAfter=true} 共 8 个（{@code 40105} + {@code 42901}–{@code 42907}），
 * 抛异常时必须提供剩余秒数，缺即实现缺陷（编码规范 §3.2；PRD §12.5「Retry-After 响应头」补充条款）。
 */
public enum ErrorCode {

    /** PRD §12.5：成功。 */
    OK(0, 200, "success", false),

    /** PRD §12.5：参数缺失或非法（含 {@code /map/pins} 缓存键要素不全）；客户端修参重试，不提示用户。 */
    PARAM_INVALID(40001, 400, "参数缺失或非法", false),

    /** PRD §12.5：协议未勾选；主按钮保持 Disabled。 */
    AGREEMENT_REQUIRED(40002, 400, "请先阅读并同意用户协议与隐私政策", false),

    /** PRD §12.5：未登录 / Token 失效；客户端弹登录，登录成功回原页。 */
    UNAUTHORIZED(40101, 401, "登录已过期，请重新登录", false),

    /** PRD §12.5：登录失败 5 次，锁定 15 分钟；客户端按 {@code Retry-After} 显示剩余锁定时间。 */
    LOGIN_LOCKED(40105, 401, "验证码错误次数过多，请稍后再试", true),

    /** PRD §12.5：未实名详情额度耗尽（每日 3 条）；客户端弹半屏引导实名。 */
    DETAIL_QUOTA_USED(40301, 403, "今日可查看详情数量已用完", false),

    /** PRD §12.5：高敏类目未认证，禁止发布；客户端弹 cert-modal 跳认证。 */
    QUALIFICATION_NEEDED(40302, 403, "该类目需先完成资质认证", false),

    /** PRD §12.5：该类目禁发（医疗/金融/武器等）。 */
    CATEGORY_BANNED(40303, 403, "该类目当前禁止发布", false),

    /** PRD §12.5：未实名发布已达上限（每日 1 条 / 在库 3 条）；客户端引导实名。 */
    PUBLISH_LIMIT(40304, 403, "未实名用户发布数量已达上限", false),

    /** PRD §12.5：后台 RBAC 越权专用（含读与写），不透出资源是否存在；App 端不应收到此码。 */
    NO_PERMISSION(40305, 403, "无权限执行此操作", false),

    /** PRD §12.5：命中敏感词；客户端提示修改。 */
    SENSITIVE_WORD(40901, 409, "内容包含不允许发布的词汇，请修改后重试", false),

    /** PRD §12.5：图片未通过内容审核；驳回信息仅本人可见。 */
    IMAGE_REJECTED(40902, 409, "图片未通过审核，请更换后重试", false),

    /** PRD §12.5：乐观锁版本冲突；不可自动重试，须重新 GET 取新 version 后由用户决定是否再提交。 */
    VERSION_CONFLICT(40903, 409, "数据已更新，请刷新后重试", false),

    /** PRD §12.5：信息已下架/过期。 */
    POST_GONE(41001, 410, "该信息已下架或已过期", false),

    /** PRD §12.5：AI 配额耗尽；客户端按 {@code Retry-After} 提示剩余额度与重置时间，降级手动填写。 */
    AI_QUOTA_EXCEEDED(42901, 429, "今日 AI 辅助次数已用完", true),

    /** PRD §12.5：联系方式拉取超限（账号/设备/IP 任一）；收到即把本地剩余刷 0，不承诺剩余次数。 */
    CONTACT_LIMIT(42902, 429, "今日查看联系方式次数已达上限", true),

    /** PRD §12.5：异常访问熔断，当日冻结；客户端提示已受限并告知申诉入口。 */
    CIRCUIT_BROKEN(42903, 429, "操作过于频繁，该功能今日已暂停使用", true),

    /** PRD §12.5：推送频控（≤10 条/日）；服务端静默转站内通知，客户端无感。 */
    PUSH_LIMIT(42904, 429, "推送发送过于频繁", true),

    /** PRD §12.5：验证码发送频控（同手机号或同 IP 超限）；按 {@code Retry-After} 倒计时置灰，不可自动重试。 */
    SMS_LIMIT(42905, 429, "验证码发送过于频繁，请稍后再试", true),

    /** PRD §12.5：埋点上报频控——唯一不向用户呈现的错误码；事件退回本地队列按 {@code Retry-After} 延后重试。 */
    TRACK_LIMIT(42906, 429, "track rate limited", true),

    /** PRD §12.5：未登录详情浏览超限（设备 30 / IP 100 每日，任一超限）——仅未登录请求生效，不告知命中维度。 */
    GUEST_DETAIL_LIMIT(42907, 429, "今日浏览次数较多，登录后可继续查看", true),

    /** PRD §12.5：服务端内部错误；客户端通用重试 + 回显 {@code request_id}。 */
    INTERNAL_ERROR(50001, 500, "服务繁忙，请稍后重试", false),

    /** PRD §12.5：AI 解析不可用（超时/无返回/图不可识别）；已输入内容全保留。 */
    AI_UNAVAILABLE(50301, 503, "AI 服务暂时不可用，请稍后重试", false),

    /** PRD §12.5：第三方认证服务不可用；支持手动重填字段 + 转人工复核。 */
    CERT_UNAVAILABLE(50302, 503, "认证服务暂时不可用，请稍后重试", false),

    /** PRD §12.5：地图/定位服务不可用；定位失败 ≥3 次降级手动选城市。 */
    GEO_UNAVAILABLE(50303, 503, "定位服务暂时不可用，请稍后重试", false);

    private final int code;
    private final int httpStatus;
    private final String message;
    private final boolean needRetryAfter;

    /**
     * 构造错误码枚举项（四元组逐字对齐详设 §2.3 定义）。
     *
     * @param code           业务码，{@code 0} 成功；非 0 前 3 位与 HTTP 状态码对齐
     * @param httpStatus     HTTP 状态码，与 {@code code} 同时使用（HTTP 表达传输层，code 表达业务语义）
     * @param message        中文文案，非 0 时可直接呈现给用户（{@code 42906} 例外：不向用户呈现）
     * @param needRetryAfter 抛出该码异常时是否必须携带剩余秒数（供 {@code Retry-After} 响应头使用）
     * @return 无返回值（枚举构造器）
     */
    ErrorCode(int code, int httpStatus, String message, boolean needRetryAfter) {
        this.code = code;
        this.httpStatus = httpStatus;
        this.message = message;
        this.needRetryAfter = needRetryAfter;
    }

    /**
     * 取业务码。
     *
     * @param 无入参
     * @return int 业务码，写入 {@code ApiResponse.code} 字段
     */
    public int getCode() {
        return code;
    }

    /**
     * 取 HTTP 状态码。
     *
     * @param 无入参
     * @return int HTTP 状态码，供 {@code GlobalExceptionHandler} 构造 {@code ResponseEntity} 使用
     */
    public int getHttpStatus() {
        return httpStatus;
    }

    /**
     * 取中文文案。
     *
     * @param 无入参
     * @return {@link String} 用户可读文案，写入 {@code ApiResponse.message} 字段
     */
    public String getMessage() {
        return message;
    }

    /**
     * 取该码是否要求携带剩余秒数。
     *
     * @param 无入参
     * @return boolean；{@code true} 表示抛异常必须带剩余秒数（{@code Retry-After}），缺即实现缺陷
     */
    public boolean isNeedRetryAfter() {
        return needRetryAfter;
    }
}
