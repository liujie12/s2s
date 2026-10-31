package com.s2s.server.contact;

/**
 * 联系事件渠道取值（{@code contact_event.channel_type}；V30 扩为四值）。
 *
 * <p>为什么收成常量：写入点分散在取号链路（{@code phone}/{@code wechat}）与会话链路
 * （{@code conversation}，申请同意时升级为 {@code apply}），两处各写一份字符串时
 * 新增渠道必然漏改一处，且拼错不会在编译期暴露。取值须与 DDL 的 ENUM 逐字一致。</p>
 */
public final class ContactChannel {

    /**
     * 工具类：禁止实例化。
     */
    private ContactChannel() {
        throw new AssertionError("ContactChannel 是常量类，不可实例化");
    }

    /** 会话渠道：会话首条消息写入（R31 / KTD11）。 */
    public static final String CONVERSATION = "conversation";

    /** 申请渠道：申请被同意时把同一条事件的渠道升级为本值（R31 / KTD11）。 */
    public static final String APPLY = "apply";
}
