package com.s2s.server.contact;

/**
 * 举报原因枚举——{@code report.reason} 列取值的唯一落点
 * （DDL {@code V1__init_schema.sql:266}；openapi {@code POST /posts/{id}/report} 的
 * {@code reason} enum；详设 §5.5.2「与 {@code report.reason} 列<b>严格一致</b>」）。
 *
 * <p><b>为什么必须用枚举校验而不是「非空即可」</b>：{@code reason} 是 MySQL
 * {@code ENUM} 列，写入枚举外的值在严格模式下报错（表现为 50001，把客户端的参数
 * 错误伪装成服务端故障），在非严格模式下则静默存空串（举报记录失去原因，
 * 永远无法进入 §9.10.3 的权重累计）。校验放在落库前，两种坏结果都避免。</p>
 *
 * <p>客户端传 {@code reason} 非法值属参数错误，回 {@code 40001}（客户端按
 * 「修参重试、不提示用户」处理，编码规范 §4.12）。</p>
 */
public enum ReportReason {

    /** 不实信息。 */
    FALSE_INFO("false_info"),

    /** 诈骗。 */
    FRAUD("fraud"),

    /** 违规类目。 */
    WRONG_CATEGORY("wrong_category"),

    /** 骚扰。 */
    HARASSMENT("harassment"),

    /** 其他。 */
    OTHER("other"),

    /**
     * 敏感词误拦反馈（R28）。
     *
     * <p>与其余五项的区别：本值由「消息正文被拒发」的误拦入口写入，不是用户举报
     * 他人，而是用户反馈审核误判。复用同一张 {@code report} 表与同一处置队列，
     * 后台按原因筛选即可把误拦反馈单独拉出复核。</p>
     */
    MISBLOCK("misblock");

    /** 落库值（与 DDL {@code ENUM} 逐字一致）。 */
    private final String dbValue;

    /**
     * 构造举报原因枚举项。
     *
     * @param dbValue 落库值（{@code report.reason} 列的合法取值之一）
     */
    ReportReason(String dbValue) {
        this.dbValue = dbValue;
    }

    /**
     * 取落库值。
     *
     * @return {@link String} 与 DDL {@code ENUM} 一致的字符串
     */
    public String dbValue() {
        return dbValue;
    }

    /**
     * 判断入参是否为契约声明的合法举报原因（含「误拦」）。
     *
     * <p>会话内举报与误拦反馈用本方法：两者共用同一落库路径，原因都落在
     * {@code report.reason} 列的合法值域内。</p>
     *
     * @param apiValue 客户端传入的 {@code reason} 原值（可能为 null）
     * @return boolean；六个合法值之一为 {@code true}，其余（含 null）为 {@code false}
     */
    public static boolean isValid(String apiValue) {
        for (ReportReason reason : values()) {
            if (reason.dbValue.equals(apiValue)) {
                return true;
            }
        }
        return false;
    }

    /**
     * 判断入参是否为「可对帖子/用户发起举报」的原因（五值，不含误拦）。
     *
     * <p>误拦反馈只能经会话内的误拦入口提交：它反馈的是审核误判，不是对被举报对象的
     * 指控；若允许 {@code POST /posts/{id}/report} 直接带该值，帖子举报队列里会混入
     * 不计风险分的噪声工单。</p>
     *
     * @param apiValue 客户端传入的 {@code reason} 原值（可能为 null）
     * @return boolean；五值之一为 {@code true}，{@code misblock} 与非法值为 {@code false}
     */
    public static boolean isReportable(String apiValue) {
        return isValid(apiValue) && !MISBLOCK.dbValue.equals(apiValue);
    }
}
