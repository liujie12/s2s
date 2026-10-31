package com.s2s.server.chat;

/**
 * 会话域接口专用文案（KTD4 的三处例外 + 本域其余固定提示）。
 *
 * <p><b>为什么集中在这里</b>：这些文案要与错误码全局文案区分——{@code 40305} 的全局文案是
 * 「无权限执行此操作」，{@code 42902} 是「今日查看联系方式次数已达上限」；直接用全局文案
 * 会让用户看到与场景不符的提示。集中成常量也避免同一句中文在多处复制后逐渐走样。</p>
 *
 * <p>错误码、码值与 HTTP 状态完全不因此改变，仅文案覆盖。</p>
 */
public final class ChatCopy {

    /**
     * 工具类：禁止实例化。
     */
    private ChatCopy() {
        throw new AssertionError("ChatCopy 是常量类，不可实例化");
    }

    /** 消息总开关关闭时的统一提示（R30；创建会话、发放申请卡、发送消息三处共用）。 */
    public static final String MAINTENANCE = "消息功能维护中，请稍后再试";

    /** 每日新会话额度超限提示（R27；复用 42902，仅本接口使用此文案）。 */
    public static final String NEW_CONVERSATION_LIMIT = "今日发起会话数已达上限";

    /** 需申请帖的取号闸门提示（R22 / R24；复用 40305）。 */
    public static final String APPLY_REQUIRED = "该发布者设置了查看联系方式需申请，请先在会话中申请";

    /** 未回复达上限时的输入区提示（R26）。 */
    public static final String UNREPLIED_LIMIT = "等待对方回复后可继续发送";

    /** 会话不存在或当前用户不是成员时的提示（R32：两者同一响应，不泄露会话存在性）。 */
    public static final String CONVERSATION_NOT_FOUND = "会话不存在或已不可访问";
}
