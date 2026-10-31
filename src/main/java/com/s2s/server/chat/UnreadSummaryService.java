package com.s2s.server.chat;

import com.s2s.server.chat.dto.UnreadSummaryResponse;
import com.s2s.server.chat.mapper.MessageMapper;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.notify.NotifyService;
import java.time.LocalDateTime;
import org.springframework.stereotype.Service;

/**
 * 未读汇总唯一出口（V30 / 计划 U5；KTD9 / R8）。
 *
 * <p><b>为什么只此一处产出总数</b>：R8 要求未读只有一个计算口径。Tab 角标、会话行红点、
 * 安卓桌面角标若各自把「消息未读 + 通知未读」加一遍，三处取数时刻不同就会给出三个
 * 数字（成功标准明写「三处数字在同一时刻指向同一个值」）。</p>
 *
 * <p><b>不缓存</b>：读路径直算，避免与写入路径产生第二个真源；单用户会话与通知量级为
 * 百级，两次计数查询的成本低于一处缓存失效缺陷。</p>
 */
@Service
public class UnreadSummaryService {

    private final MessageMapper messageMapper;
    private final NotifyService notifyService;

    /**
     * 构造未读汇总服务。
     *
     * @param messageMapper 消息持久层（会话未读计数）
     * @param notifyService 通知域服务（通知未读计数，跨域只调 service）
     */
    public UnreadSummaryService(MessageMapper messageMapper, NotifyService notifyService) {
        this.messageMapper = messageMapper;
        this.notifyService = notifyService;
    }

    /**
     * 汇总当前用户的未读（{@code GET /unread-summary}）。
     *
     * @param userId 当前登录用户 ID（控制器已保证非 null）
     * @return {@link UnreadSummaryResponse} 总数 + 会话未读 + 通知未读
     */
    public UnreadSummaryResponse summary(Long userId) {
        // 隐藏会话不计入未读：用户已在列表看不到它，红点却一直亮着会变成无法消除的噪音（R5）
        LocalDateTime visibleSince =
                LocalDateTime.now().minusDays(ChatLimits.CONVERSATION_HIDE_AFTER_DAYS);
        long conversationUnread = messageMapper.countUnreadForUser(userId, visibleSince);
        long notificationUnread = notifyService.countUnread(userId);
        return new UnreadSummaryResponse(conversationUnread + notificationUnread,
                conversationUnread, notificationUnread);
    }
}
