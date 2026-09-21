package com.s2s.server.auth;

/**
 * 短信验证码策略常量（[123] U4；plan KTD1 + Assumptions）。
 *
 * <p>承载验证码有效期、dev 桩固定码、存储键前缀三项短信验证码策略常量，均为
 * 「不复制字面量」红线下的单点真源。依据：
 * <ul>
 *   <li>有效期 300 秒（5 分钟）：plan KTD1「TTL 5 分钟（expire_in = 300 秒）」，
 *       与前端 {@code kSmsCodeTtl = Duration(minutes: 5)} 同口径（编码规范 §3.1 双端对账）；</li>
 *   <li>dev 桩固定码 888888：plan Assumptions「短信渠道用 dev 桩（固定验证码 888888），
 *       不接真服务商」，Batch1 联调用；正式接入短信服务商后改随机 6 位数字（KTD8 出包前删后门）；</li>
 *   <li>存储键前缀 sms:：plan KTD1「Redis 键 sms:{phone}」。</li>
 * </ul>
 *
 * <p>出处：plan KTD1（验证码存储结构）、Assumptions（dev 桩）、PRD §12.2。</p>
 */
public final class SmsCodePolicy {

    /**
     * 私有构造器：常量类禁止实例化（范式同 {@code ErrorCode}）。
     */
    private SmsCodePolicy() {
        throw new AssertionError("SmsCodePolicy 是常量类，不可实例化");
    }

    /** 验证码有效期（秒）= 5 分钟。plan KTD1；前端 {@code kSmsCodeTtl} 同口径。 */
    public static final int CODE_TTL_SECONDS = 300;

    /** dev 桩固定验证码。plan Assumptions；Batch1 不接真短信服务商，正式接入后改随机。 */
    public static final String DEBUG_CODE = "888888";

    /** 验证码存储键前缀。plan KTD1「Redis 键 {@code sms:{phone}}」。 */
    public static final String SMS_KEY_PREFIX = "sms:";
}
