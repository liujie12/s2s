package com.s2s.server.common.constants;

/**
 * 运营治理后台（[153] B2-5）非功能常量 —— 阈值/TTL/上限的**唯一数值落点**
 * （编码规范 §3.1：阈值只引用常量名，业务代码禁写死数字）。
 *
 * <p>说明：PRD / 详设**未定义**后台 Token 有效期与口令哈希参数（后台为 Batch2 新增面），
 * 本类承载其**实现默认值**，待需求侧评审后如有正式口径，改本类一处即可。</p>
 */
public final class NfrAdmin {

    /**
     * 工具类：禁止实例化。
     */
    private NfrAdmin() {
        throw new AssertionError("NfrAdmin 是常量类，不可实例化");
    }

    /** 后台 Token 有效期（分钟）。后台为高权限面，有效期显著短于 C 端 Token（2 小时）。 */
    public static final long TOKEN_TTL_MINUTES = 120L;

    /** 口令哈希 PBKDF2 迭代次数（口令存储强度下限）。 */
    public static final int PASSWORD_PBKDF2_ITERATIONS = 120_000;

    /** 口令哈希盐长度（字节，随机生成）。 */
    public static final int PASSWORD_SALT_BYTES = 16;

    /** 口令哈希输出长度（bit）。 */
    public static final int PASSWORD_HASH_BITS = 256;

    /** 后台列表类接口默认每页条数（审计查询 / 审核队列 / 工单列表通用）。 */
    public static final int PAGE_SIZE_DEFAULT = 20;

    /** 后台列表类接口每页条数上限（防一次拉全表）。 */
    public static final int PAGE_SIZE_MAX = 100;

    /** 后台口令最小长度（实现默认值；PRD 未定义口令策略，与其它项同口径待评审）。 */
    public static final int PASSWORD_MIN_LENGTH = 8;

    /**
     * 批量处理类接口单次上限（如举报工单批量处理）。
     *
     * <p>不设上限会让一次请求触发无界的下架/回撤写入，可能长时间持锁；
     * 超过上限一律 {@code 40001}（参数错），而不是静默截断 —— 静默截断会让
     * 运营以为「全处理完了」。</p>
     */
    public static final int BATCH_MAX = 100;

    /**
     * 审计导出单次最大行数（实现默认值；PRD §9.10.1 只说「导出需二次确认」未定量）。
     *
     * <p>导出为同步接口，不设上限会让一次请求把 180 天全量审计（可达数十万行）
     * 一次性拉进内存并序列化，既拖垮后台也可能 OOM。超上限时导出<b>前 N 行</b>
     * 并在响应里回传实际行数，由调用方按需收窄时间/角色筛选。</p>
     */
    public static final int AUDIT_EXPORT_MAX_ROWS = 10_000;
}
