package com.s2s.server.chat;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.chat.dto.ConversationBody;
import com.s2s.server.chat.dto.ConversationReportRequest;
import com.s2s.server.chat.dto.MessageItem;
import com.s2s.server.chat.entity.ConversationEntity;
import com.s2s.server.chat.entity.ConversationMemberEntity;
import com.s2s.server.chat.entity.MessageEntity;
import com.s2s.server.chat.mapper.ConversationMapper;
import com.s2s.server.chat.mapper.ConversationMemberMapper;
import com.s2s.server.chat.mapper.MessageMapper;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.contact.ContactService;
import com.s2s.server.contact.ReportReason;
import com.s2s.server.contact.dto.ReportResult;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.springframework.stereotype.Service;

/**
 * 会话内举报与误拦反馈（V30 / 计划 U7；R28 / R29 / KTD10）。
 *
 * <p><b>对象只有一个</b>：本版只支持举报「对方用户」，帖子取会话所锚定的那一条，
 * 不新增「会话」与「单条消息」两类举报对象（R29）——两类新对象会让后台多出两套
 * 处置口径，而现有工单表已经以帖子为锚积累了风险分与处置流程。</p>
 *
 * <p><b>下架帖仍可举报</b>：不校验帖子可见性（R29），因为举报发生在会话里，
 * 帖子下架不该同时剥夺用户对骚扰行为的投诉权。落库、风险分、审计与后台队列
 * 全部复用 contact 域既有实现（KTD10），本类只负责把「会话」翻译成
 * 「帖子 + 对方用户 + 举报人」。</p>
 *
 * <p><b>日志纪律</b>：本类不打印任何消息正文、联系方式或举报描述。</p>
 */
@Service
public class ChatReportService {

    /** 误拦反馈描述里「原文」前缀：让后台一眼看出后面是被拦截的正文摘要（R28）。 */
    private static final String MISBLOCK_TEXT_PREFIX = "误拦反馈｜原文：";

    private final ConversationMapper conversationMapper;
    private final ConversationMemberMapper memberMapper;
    private final MessageMapper messageMapper;
    private final ContactService contactService;

    /**
     * 构造会话举报服务。
     *
     * @param conversationMapper 会话持久层（取会话与后台复核定位）
     * @param memberMapper       会话成员持久层（成员校验，R32）
     * @param messageMapper      消息持久层（后台复核取正文）
     * @param contactService     contact 域服务（举报落库、风险分与审计的唯一实现）
     */
    public ChatReportService(ConversationMapper conversationMapper,
            ConversationMemberMapper memberMapper,
            MessageMapper messageMapper,
            ContactService contactService) {
        this.conversationMapper = conversationMapper;
        this.memberMapper = memberMapper;
        this.messageMapper = messageMapper;
        this.contactService = contactService;
    }

    /**
     * 举报会话中的对方用户（{@code POST /conversations/{id}/report}，R28 / R29）。
     *
     * <p>被举报人恒为对方成员：发起人会话的对方是发布者，发布者会话的对方是发起人。
     * 误拦反馈（{@code reason=misblock}）走同一写入路径，描述里带上被拦原文摘要。</p>
     *
     * @param userId         当前登录用户 ID（举报人）
     * @param conversationId 会话 ID
     * @param request        举报入参
     * @return {@link ReportResult} 举报 ID + 初始状态 pending
     * @throws BizException {@code 40305} 非成员（与「会话不存在」同一响应）；
     *         {@code 40001} 原因非法；{@code 41001} 会话对应的帖子行已不存在
     */
    public ReportResult report(Long userId, Long conversationId,
            ConversationReportRequest request) {
        requireMember(conversationId, userId);
        if (!ReportReason.isValid(request.reason())) {
            // 原因白名单在落库前校验：ENUM 列写入非法值会变成 50001 或静默空串
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        ConversationEntity conversation = conversationMapper.selectById(conversationId);
        if (conversation == null) {
            throw notFound();
        }
        Long counterpartId = userId.equals(conversation.getInitiatorId())
                ? conversation.getOwnerId()
                : conversation.getInitiatorId();
        String description = ReportReason.MISBLOCK.dbValue().equals(request.reason())
                ? misblockDescription(request)
                : request.remark();
        return contactService.reportInConversation(userId, conversation.getPostId(),
                counterpartId, request.reason(), description, request.evidence());
    }

    /**
     * 按举报的帖子与双方用户定位会话并取最近一页正文（后台复核用，计划 U7）。
     *
     * <p>只按「会话锚定帖子 + 发起人属于举报双方」定位：{@code uk_post_initiator}
     * 保证同一帖子对同一发起人只有一条会话，故不会取到第三方的会话。</p>
     *
     * @param postId          举报关联的帖子 ID
     * @param firstUserId     举报双方之一（举报人）
     * @param secondUserId    举报双方之二（被举报人）
     * @return {@link ConversationBody} 会话 ID + 按 seq 正序的消息
     * @throws BizException {@code 41001} 双方之间没有会话（帖子下架不影响会话存在性）
     */
    public ConversationBody bodyForReport(Long postId, Long firstUserId, Long secondUserId) {
        ConversationEntity conversation = conversationMapper.selectOne(
                new QueryWrapper<ConversationEntity>()
                        .eq("post_id", postId)
                        .in("initiator_id", firstUserId, secondUserId));
        if (conversation == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        List<MessageEntity> rows = new ArrayList<>(messageMapper.selectRecentByConversation(
                conversation.getId(), ChatLimits.MESSAGE_PAGE_MAX_SIZE));
        // 倒序取最近一页，翻成正序返回：复核阅读顺序与双方看到的一致
        Collections.reverse(rows);

        List<MessageItem> items = new ArrayList<>(rows.size());
        for (MessageEntity message : rows) {
            items.add(new MessageItem(message.getId(), message.getSeq(), message.getSenderId(),
                    message.getType(), message.getContent(),
                    message.getCreatedAt().toInstant(ZoneOffset.UTC)));
        }
        return new ConversationBody(conversation.getId(), items);
    }

    /**
     * 组装误拦反馈描述：原文摘要优先，补充说明在前，整体截断到消息正文上限。
     *
     * <p>截断而非拒绝：误拦反馈的价值在于「原文是什么」，超长原文截断后仍可复核；
     * 拒绝提交会让用户连反馈入口都用不了。</p>
     *
     * @param request 举报入参
     * @return {@link String} 落 {@code report.description} 的描述；无原文时退回 {@code remark}
     */
    private String misblockDescription(ConversationReportRequest request) {
        String blocked = request.blockedText();
        if (blocked == null || blocked.isBlank()) {
            return request.remark();
        }
        String combined = request.remark() == null || request.remark().isBlank()
                ? MISBLOCK_TEXT_PREFIX + blocked
                : request.remark() + MISBLOCK_TEXT_PREFIX + blocked;
        return combined.length() <= ChatLimits.MESSAGE_CONTENT_MAX_LENGTH
                ? combined
                : combined.substring(0, ChatLimits.MESSAGE_CONTENT_MAX_LENGTH);
    }

    /**
     * 断言当前用户是会话成员（R32：非成员与不存在同一响应）。
     *
     * @param conversationId 会话 ID
     * @param userId         当前用户 ID
     * @throws BizException {@code 40305}，文案为「会话不存在或已不可访问」
     */
    private void requireMember(Long conversationId, Long userId) {
        ConversationMemberEntity member = memberMapper.selectMember(conversationId, userId);
        if (member == null) {
            throw notFound();
        }
    }

    /**
     * 构造「会话不存在或不可访问」异常（与成员校验同一响应，R32）。
     *
     * @return {@link BizException} {@code 40305} + 专用文案
     */
    private BizException notFound() {
        return BizException.of(ErrorCode.NO_PERMISSION, ChatCopy.CONVERSATION_NOT_FOUND);
    }
}
