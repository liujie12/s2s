package com.s2s.server.common.constants;

/**
 * 推送域 NFR 常量（[B2-2]；PRD §6.14 / §12.3）。
 *
 * <p><b>为什么单独成类</b>：按「不复制字面量」硬纪律（编码规范 §3.1），阈值必须只引用
 * 常量名。推送每日配额此前只活在 PRD 表格里，代码侧一旦手敲 {@code 10} 就无处对账。</p>
 *
 * <p><b>单端口径（无 Dart 镜像）</b>：与 {@code NfrApi}/{@code NfrCert} 的双端镜像不同，
 * 本配额是**服务端自限**（客户端不需要知悉「还能收几条」，超限时它什么都收不到，
 * 通知照常在站内中心可见）。故不建 Dart 镜像——若将来前端要展示「今日推送已达上限」，
 * 再按双端纪律补 {@code NfrPush} 镜像并加对账断言。</p>
 */
public final class NfrPush {

    /**
     * 私有构造器：常量类禁止实例化（范式同 {@code NfrApi}）。
     */
    private NfrPush() {
    }

    /**
     * 单用户每日接收推送上限（条）。PRD §6.14「推送频控：单用户每日接收推送 ≤10 条，
     * 避免骚扰」、§12.3「`42904` 推送频控（≤10 条/日）」。
     *
     * <p><b>超出后的行为不是报错</b>：PRD §12.3 明写「服务端静默转站内通知，客户端无感」
     * ——超限只停止**通道下发**，站内通知该写照写。故消费方（{@code PushQuotaGate}）
     * 返回布尔而非抛 {@code 42904}；{@code 42904} 保留给「推送发送过于频繁」的
     * 显式受限场景（如运营后台定向邀请被频控）。</p>
     */
    public static final int DAILY_LIMIT = 10;

    /**
     * 厂商推送服务端 HTTP 调用的连接/读取超时（秒）。
     *
     * <p><b>为什么是 5 秒</b>：推送是「尽力而为」的下发链路，站内通知已在同事务内落库；
     * 厂商接口若 5 秒未响应，继续等待只会拖住调用方线程，收益为零。与
     * {@code NfrAi#UPSTREAM_TIMEOUT_SECONDS}（10 秒）刻意不同 —— 后者是用户主动等待的
     * 交互链路，本项是后台旁路。</p>
     */
    public static final int UPSTREAM_TIMEOUT_SECONDS = 5;

    /**
     * 小米通知标题最大字符数（官方口径：长度小于 50，中英文均按 1 计）。
     */
    public static final int XIAOMI_TITLE_MAX_CHARS = 50;

    /**
     * 小米通知描述最大字符数（官方口径：长度小于 128，中英文均按 1 计）。
     */
    public static final int XIAOMI_DESCRIPTION_MAX_CHARS = 128;
}
