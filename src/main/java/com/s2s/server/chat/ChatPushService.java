package com.s2s.server.chat;

import com.s2s.server.admin.config.AdminConfigKeys;
import com.s2s.server.auth.SettingService;
import com.s2s.server.chat.mapper.ConversationMemberMapper;
import com.s2s.server.common.config.SystemConfigService;
import com.s2s.server.notify.NotifyType;
import com.s2s.server.notify.PushDispatchService;
import com.s2s.server.notify.PushMessage;
import org.springframework.stereotype.Service;

/**
 * 新消息推送编排（V30 / 计划 U9；R14 / R14a / KTD6 / KTD7）。
 *
 * <p><b>只推不落通知</b>（KTD6）：消息推送走 {@link PushDispatchService#pushOnly}，
 * 不写 {@code notification} 表——否则同一条消息会同时进入「会话未读」与「通知未读」，
 * 与 R8 的单一未读口径冲突。</p>
 *
 * <p><b>未读期间只推首条</b>（KTD7）：以成员行的 {@code pushed_unread} 做原子抢占，
 * 抢不到即说明本轮未读已经推过；读会话时该标记复位。</p>
 *
 * <p><b>三处不推</b>：消息总开关关闭、接收方关闭「消息通知」、配置文件缺行以外的通道
 * 不可用——前两者在这里短路，后者由发送编排静默降级（配额用尽、无发送器都不报错）。</p>
 *
 * <p><b>载荷纪律</b>：只带固定文案与会话 ID，不含消息正文、联系方式与对方以外的人名
 * （R14）。</p>
 */
@Service
public class ChatPushService {

    private final SystemConfigService systemConfigService;
    private final SettingService settingService;
    private final ConversationMemberMapper memberMapper;
    private final PushDispatchService pushDispatchService;

    /**
     * 构造消息推送编排。
     *
     * @param systemConfigService 系统配置（消息总开关）
     * @param settingService      用户设置（「消息通知」开关，跨域只调 service）
     * @param memberMapper        会话成员持久层（未读期间已推送标记）
     * @param pushDispatchService 推送下发编排（只推不落通知）
     */
    public ChatPushService(SystemConfigService systemConfigService, SettingService settingService,
            ConversationMemberMapper memberMapper, PushDispatchService pushDispatchService) {
        this.systemConfigService = systemConfigService;
        this.settingService = settingService;
        this.memberMapper = memberMapper;
        this.pushDispatchService = pushDispatchService;
    }

    /**
     * 新消息落库后尝试推送（首条生效，其余静默跳过）。
     *
     * <p>本方法不抛业务异常：推送失败不能回滚已落库的消息（R14a 允许前台拉取兜底）。</p>
     *
     * @param receiverId     接收者 user_id（调用方保证非 null）
     * @param conversationId 会话 ID（载荷 targetId）
     */
    public void notifyNewMessage(Long receiverId, Long conversationId) {
        if (!systemConfigService.isOnOrAbsent(AdminConfigKeys.MESSAGE_ENABLED)) {
            return;
        }
        if (!settingService.isMessageNotifyEnabled(receiverId)) {
            return;
        }
        if (memberMapper.markPushed(conversationId, receiverId) == 0) {
            // 本轮未读已经推过首条（或不是成员）：不重复打扰
            return;
        }
        pushDispatchService.pushOnly(receiverId, new PushMessage(NotifyType.INTERACTION,
                ChatCopy.PUSH_TITLE, ChatCopy.PUSH_SUMMARY, conversationId,
                PushMessage.LANDING_CONVERSATION));
    }
}
