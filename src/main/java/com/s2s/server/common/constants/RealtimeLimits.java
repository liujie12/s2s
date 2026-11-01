package com.s2s.server.common.constants;

/**
 * 实时消息通道常量（WebSocket + Redis Pub/Sub）。
 *
 * <p>职责：承载连接层与投递层的全部阈值——单用户/单实例连接上限、慢客户端保护参数、
 * 心跳帧与关闭码。业务代码只引用常量名，禁写字面量（编码规范红线「不复制字面量」）。</p>
 *
 * <p><b>为什么单实例上限是 3000</b>：当前部署为单实例、JVM {@code -Xmx600m}，
 * 每条 WebSocket 连接连同 Tomcat socket 缓冲估算 15–25KB，给实时通道预留约 150MB，
 * 安全线约 5k 连接。先取 3000 留出业务峰值余量，<b>压测校准后再调</b>；
 * 扩容时按「连接数 &gt; 本值 70%」触发加实例（详见部署手册实时通道章节）。</p>
 *
 * <p>关闭码用 WebSocket 允许的自定义段 4000–4999，<b>不是</b>业务错误码
 * （错误码唯一口径仍是 PRD §12.5，禁止在此占号）。</p>
 */
public final class RealtimeLimits {

    /**
     * 工具类：禁止实例化。
     */
    private RealtimeLimits() {
        throw new AssertionError("RealtimeLimits 是常量类，不可实例化");
    }

    // --- 总线 ---------------------------------------------------------------------

    /** Redis 发布订阅频道：消息落库后由发布方 write，全实例订阅后只投本机连接。 */
    public static final String MESSAGE_CHANNEL = "s2s:rt:message";

    /** 事件类型：新消息（客户端据此增量拉取，不直接携带正文）。 */
    public static final String EVENT_MESSAGE_NEW = "message.new";

    /** 事件类型：对方已读水位推进（发送方据此把气泡从「未读」改为「已读」）。 */
    public static final String EVENT_CONVERSATION_READ = "conversation.read";

    // --- 连接上限 -----------------------------------------------------------------

    /** 单用户最大同时连接数（多端）：超出时踢掉最早建立的连接，不拒绝新端。 */
    public static final int MAX_SESSIONS_PER_USER = 3;

    /** 单实例最大连接数：超出即拒绝新连接，防止单机内存被长连接吃穿。 */
    public static final int MAX_SESSIONS_PER_INSTANCE = 3_000;

    // --- 慢客户端保护 -------------------------------------------------------------

    /** 单次发送时间上限（毫秒）：超时说明对端不收包，直接断开，避免拖住投递线程。 */
    public static final long SEND_TIME_LIMIT_MILLIS = 5_000L;

    /** 单连接发送缓冲上限（字节）：积压超过即断开，防止弱网设备撑爆实例内存。 */
    public static final int SEND_BUFFER_LIMIT_BYTES = 512 * 1024;

    // --- 心跳与帧 -----------------------------------------------------------------

    /** 客户端心跳帧：服务端收到即回 {@link #PONG_FRAME}（保活穿中间层空闲超时）。 */
    public static final String PING_FRAME = "ping";

    /** 服务端心跳应答帧。 */
    public static final String PONG_FRAME = "pong";

    /** 客户端单帧最大字符数：心跳帧之外的任何超长帧一律断开（防大包打爆解析）。 */
    public static final int MAX_CLIENT_FRAME_CHARS = 64;

    // --- 关闭码 -------------------------------------------------------------------

    /** 关闭码：本实例连接数已达上限。 */
    public static final int CLOSE_INSTANCE_FULL = 4001;

    /** 关闭码：同用户在其它端的连接已满，本端被替换下线。 */
    public static final int CLOSE_SESSION_REPLACED = 4002;

    /** 关闭码：握手属性缺失或客户端协议异常。 */
    public static final int CLOSE_PROTOCOL_ERROR = 4003;
}
