package com.s2s.server.notify;

/**
 * 站内通知文案（PRD §8.3.3 / §6.14；集中一处，避免同一事件在不同入口写出不同措辞）。
 *
 * <p>标题 ≤64、摘要 ≤256，与 {@code notification.title/summary} 列宽及推送载荷同口径。</p>
 */
public final class NotifyCopy {

    /** 摘要最大长度（与 {@code notification.summary} 列宽一致）。 */
    public static final int SUMMARY_MAX_LENGTH = 256;

    /** 互动通知：发布被联系。 */
    public static final String CONTACTED_TITLE = "你的发布被联系了";

    /** 互动通知：发布被联系摘要。 */
    public static final String CONTACTED_SUMMARY = "有人查看了你发布的联系方式，点击查看";

    /** 系统通知：实名认证通过。 */
    public static final String REALNAME_APPROVED_TITLE = "实名认证已通过";

    /** 系统通知：实名认证通过摘要。 */
    public static final String REALNAME_APPROVED_SUMMARY = "你的实名认证已通过";

    /** 系统通知：资质认证通过。 */
    public static final String QUALIFICATION_APPROVED_TITLE = "资质认证已通过";

    /** 系统通知：资质认证通过摘要。 */
    public static final String QUALIFICATION_APPROVED_SUMMARY = "你的资质认证已通过，可在信任与认证中查看";

    /** 认证通知：审核通过。 */
    public static final String CERT_APPROVED_TITLE = "认证审核已通过";

    /** 认证通知：审核通过摘要。 */
    public static final String CERT_APPROVED_SUMMARY = "你的认证审核已通过";

    /** 认证通知：审核未通过。 */
    public static final String CERT_REJECTED_TITLE = "认证审核未通过";

    /** 认证通知：审核未通过摘要前缀。 */
    private static final String CERT_REJECTED_PREFIX = "你的认证审核未通过：";

    /** 认证通知：无理由时的兜底摘要。 */
    private static final String CERT_REJECTED_FALLBACK = "你的认证审核未通过，点击查看详情";

    /** 系统通知：内容被下架。 */
    public static final String TAKEDOWN_TITLE = "内容已被下架";

    /** 系统通知：内容被下架摘要。 */
    public static final String TAKEDOWN_SUMMARY = "你的发布因违规已被下架，点击查看详情";

    /** 工具类禁止实例化。 */
    private NotifyCopy() {
    }

    /**
     * 组装认证驳回摘要（超过列宽截断，避免写库失败）。
     *
     * @param rejectReason 审核员填写的驳回原因（可空）
     * @return {@link String} 可直接落库/推送的摘要
     */
    public static String certRejectedSummary(String rejectReason) {
        if (rejectReason == null || rejectReason.isBlank()) {
            return CERT_REJECTED_FALLBACK;
        }
        return truncate(CERT_REJECTED_PREFIX + rejectReason.trim());
    }

    /**
     * 按摘要列宽截断文本。
     *
     * @param value 原始文本
     * @return {@link String} 不超过 {@link #SUMMARY_MAX_LENGTH} 的文本
     */
    private static String truncate(String value) {
        return value.length() <= SUMMARY_MAX_LENGTH
                ? value
                : value.substring(0, SUMMARY_MAX_LENGTH);
    }
}
