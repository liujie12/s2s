package com.s2s.server.common.constants;

/**
 * 幂等轮询策略常量（计划 [122] KTD4）。
 *
 * <p><b>登记依据</b>：轮询间隔 / 总超时 / 占位哨兵串三个参数在依据源（详设 §3.3、
 * PRD §12.1）均无明文，属编码期防御默认——按 DEC-01 先例登记于《说明文档.md》
 * §2.9 gap-register（随 [122] U8 收口登记，裁定后回写本注释与消费方测试期望）。</p>
 *
 * <p><b>语义闭环</b>（KTD4）：并发请求 SETNX 失败后按 {@link #POLL_INTERVAL_MILLIS}
 * 轮询占位键，读到 {@link #PENDING_PLACEHOLDER} 继续等，读到首次成功响应 JSON 原样返回；
 * 等满 {@link #POLL_TIMEOUT_MILLIS} 仍为占位则返 {@code 50001}——客户端对同 Key 的
 * 自动重试会命中已完成的缓存，从而闭环。消费方为 {@code IdempotencyInterceptor}
 * （[122] U5），本类只存参数不实现轮询。</p>
 */
public final class IdempotencyPolicy {

    /**
     * 私有构造器：常量类禁止实例化（范式同 {@code ErrorCode}）。
     */
    private IdempotencyPolicy() {
    }

    /** 并发/重放占位轮询间隔（毫秒）。KTD4（依据源无明文，gap-register 登记项，
     * 先例 DEC-01）；附注：每等待者 10s 内约 50 次 Redis GET，读放大复核见 [130]。 */
    public static final long POLL_INTERVAL_MILLIS = 200;

    /** 占位轮询总超时（毫秒）= 10 秒。KTD4：超时返 {@code 50001}，客户端同 Key
     * 重试命中完成态缓存闭环；闭环成立条件 = 首次执行在首发 10s 轮询 + 至多 2 次
     * 重试各 10s 窗口内完成（详设 §14.1 重试总数 2 次）。 */
    public static final long POLL_TIMEOUT_MILLIS = 10_000;

    /** Redis 占位键的哨兵值（KTD4 定案串）。SETNX 占位时写入，首次成功响应以完整
     * 信封 JSON 覆盖；轮询读到本串表示「首次执行进行中」。业务失败即删占位键
     * （同 Key 重放重新执行），哨兵永不作为响应返回。 */
    public static final String PENDING_PLACEHOLDER = "PENDING";
}
