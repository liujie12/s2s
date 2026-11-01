package com.s2s.server.chat;

import static com.s2s.server.common.jdbc.JdbcRowValues.toInstant;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.baomidou.mybatisplus.core.conditions.update.UpdateWrapper;
import com.s2s.server.chat.dto.ApplyDecisionRequest;
import com.s2s.server.chat.dto.ApplyStateResponse;
import com.s2s.server.chat.entity.ConversationEntity;
import com.s2s.server.chat.entity.MessageEntity;
import com.s2s.server.chat.mapper.ConversationMapper;
import com.s2s.server.chat.mapper.ConversationMemberMapper;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.contact.ContactChannel;
import com.s2s.server.contact.entity.ContactEventEntity;
import com.s2s.server.contact.mapper.ContactEventMapper;
import com.s2s.server.post.PostService;
import com.s2s.server.post.dto.PostChatAnchor;
import com.s2s.server.realtime.RealtimePublisher;
import java.time.LocalDateTime;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 联系方式申请链路（V30 / 计划 U6；R19–R25 / R31 / R32）。
 *
 * <p><b>一张卡挂在会话行上</b>（KTD2）：{@code conversation.apply_status} 是状态唯一真源，
 * 会话内的 {@code message.type=apply} 只是这张卡的可视载体。被拒后满冷却期、或待审批超过
 * 重申窗口时，复用同一张卡把状态推回待审批，<b>不新增卡片</b>（R21）。</p>
 *
 * <p><b>同意才给号码卡</b>：审批通过时写入一条 {@code type=contact}、{@code visible_to=申请人}
 * 的消息，仅申请人查得到；号码本身不在卡片上（R22）。同一条会话的联系事件由「会话」升级为
 * 「申请」，不新增事件（R31 / KTD11）。</p>
 *
 * <p><b>日志纪律</b>：本类不打印任何联系方式或消息正文。</p>
 */
@Service
public class ContactApplyService {

    private final ChatService chatService;
    private final ConversationMapper conversationMapper;
    private final ConversationMemberMapper memberMapper;
    private final ChatMessageWriter messageWriter;
    private final ContactEventMapper contactEventMapper;
    private final PostService postService;
    private final ChatPushService chatPushService;
    private final RealtimePublisher realtimePublisher;

    /**
     * 构造申请链路服务。
     *
     * @param chatService        会话主链服务（维护开关判定）
     * @param conversationMapper 会话持久层（状态读写与会话行锁）
     * @param memberMapper       会话成员持久层（成员校验）
     * @param messageWriter      消息写入唯一落点（申请卡与联系方式卡）
     * @param contactEventMapper 联系事件持久层（同意时升级渠道）
     * @param postService        帖子域服务（取「需申请」开关，跨域只调 service）
     * @param chatPushService    新消息推送（申请卡与联系方式卡，未读期间只推首条）
     * @param realtimePublisher  实时通道事件（卡片同样是消息，须与文本消息一样秒级到端）
     */
    public ContactApplyService(ChatService chatService,
            ConversationMapper conversationMapper,
            ConversationMemberMapper memberMapper,
            ChatMessageWriter messageWriter,
            ContactEventMapper contactEventMapper,
            PostService postService,
            ChatPushService chatPushService,
            RealtimePublisher realtimePublisher) {
        this.chatService = chatService;
        this.conversationMapper = conversationMapper;
        this.memberMapper = memberMapper;
        this.messageWriter = messageWriter;
        this.contactEventMapper = contactEventMapper;
        this.postService = postService;
        this.chatPushService = chatPushService;
        this.realtimePublisher = realtimePublisher;
    }

    /**
     * 提交（或再次提交）联系方式申请（{@code POST /conversations/{id}/apply}，R20 / R21）。
     *
     * <p>仅发起人可申请；首次提交写入申请卡，重新提交只把状态推回待审批。
     * 已同意时幂等返回当前状态，不重复写卡。</p>
     *
     * @param userId         当前登录用户 ID（须为会话发起人）
     * @param conversationId 会话 ID
     * @return {@link ApplyStateResponse} 提交后的卡片状态
     * @throws BizException {@code 40305} 维护中 / 非成员；{@code 40001} 非发起人、帖子无需申请、
     *         或仍在冷却 / 重申窗口内；{@code 41001} 帖子行不存在
     */
    @Transactional
    public ApplyStateResponse apply(Long userId, Long conversationId) {
        chatService.requireMessageEnabled();
        ConversationEntity conversation = lockAndRequireMember(conversationId, userId);
        if (!userId.equals(conversation.getInitiatorId())) {
            // 发布者审批而不是申请；客户端不会把按钮给发布者，此处防直接调接口
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        PostChatAnchor anchor = postService.chatAnchor(conversation.getPostId());
        if (!anchor.applyRequired()) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        ApplyStatus status = ApplyStatus.fromDb(conversation.getApplyStatus());
        LocalDateTime now = LocalDateTime.now();
        switch (status) {
            case APPROVED -> {
                // 已同意：重复提交是无效操作，但返回状态而非报错，客户端刷新后入口自然置灰
                return buildState(userId, conversation, anchor, status, now);
            }
            case PENDING -> {
                requireOutsideWindow(conversation.getApplyAt(),
                        ChatLimits.APPLY_PENDING_REAPPLY_HOURS, true);
                updateApplyState(conversationId, ApplyStatus.PENDING, now);
                conversation.setApplyAt(now);
            }
            case REJECTED -> {
                requireOutsideWindow(conversation.getApplyDecidedAt(),
                        ChatLimits.APPLY_REJECT_COOLDOWN_DAYS, false);
                updateApplyState(conversationId, ApplyStatus.PENDING, now);
                conversation.setApplyStatus(ApplyStatus.PENDING.dbValue());
                conversation.setApplyAt(now);
            }
            case NONE -> {
                updateApplyState(conversationId, ApplyStatus.PENDING, now);
                conversation.setApplyStatus(ApplyStatus.PENDING.dbValue());
                conversation.setApplyAt(now);
                MessageEntity card = messageWriter.appendLocked(
                        conversation, userId, MessageType.APPLY, null, null);
                // 申请卡也是一条消息：推给接收方（未读期间只推首条，KTD7），
                // 并发布实时事件——否则对方停在会话里也要等下一次轮询才看得到卡片
                chatPushService.notifyNewMessage(conversation.getOwnerId(), conversationId);
                realtimePublisher.publishMessageNew(
                        conversation.getOwnerId(), conversationId, card.getSeq(), userId);
            }
            default -> throw new IllegalStateException("未覆盖的申请状态: " + status);
        }
        return buildState(userId, conversation, anchor, ApplyStatus.PENDING, now);
    }

    /**
     * 审批申请卡（{@code POST /conversations/{id}/apply/decision}，R21 / R22）。
     *
     * <p>同意时写入仅申请人可见的联系方式卡，并把同会话的联系事件渠道升级为「申请」；
     * 拒绝只改状态，卡片保留以便展示倒计时（R21a）。</p>
     *
     * @param userId         当前登录用户 ID（须为帖子发布者）
     * @param conversationId 会话 ID
     * @param request        审批入参（同意 / 拒绝）
     * @return {@link ApplyStateResponse} 审批后的卡片状态
     * @throws BizException {@code 40305} 维护中 / 非成员；{@code 40001} 非发布者或卡片不在待审批
     */
    @Transactional
    public ApplyStateResponse decide(Long userId, Long conversationId,
            ApplyDecisionRequest request) {
        chatService.requireMessageEnabled();
        ConversationEntity conversation = lockAndRequireMember(conversationId, userId);
        if (!userId.equals(conversation.getOwnerId())) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        if (ApplyStatus.fromDb(conversation.getApplyStatus()) != ApplyStatus.PENDING) {
            // 已处理过的卡片不再处理：重复同意会写出第二张联系方式卡
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        ApplyStatus target = Boolean.TRUE.equals(request.approved())
                ? ApplyStatus.APPROVED
                : ApplyStatus.REJECTED;
        LocalDateTime now = LocalDateTime.now();
        updateApplyState(conversationId, target, now);

        if (target == ApplyStatus.APPROVED) {
            MessageEntity card = messageWriter.appendLocked(conversation, userId, MessageType.CONTACT, null,
                    conversation.getInitiatorId());
            upgradeContactEventChannel(conversationId);
            // 联系方式卡仅申请人可见，推送与实时事件也只发给申请人
            chatPushService.notifyNewMessage(conversation.getInitiatorId(), conversationId);
            realtimePublisher.publishMessageNew(
                    conversation.getInitiatorId(), conversationId, card.getSeq(), userId);
        }
        conversation.setApplyStatus(target.dbValue());
        conversation.setApplyDecidedAt(now);
        return buildState(userId, conversation,
                postService.chatAnchor(conversation.getPostId()), target, now);
    }

    /**
     * 查询申请卡状态（{@code GET /conversations/{id}/apply}，R21a / R24）。
     *
     * @param userId         当前登录用户 ID
     * @param conversationId 会话 ID
     * @return {@link ApplyStateResponse} 卡片状态与两个入口可用性
     * @throws BizException {@code 40305} 非成员；{@code 41001} 帖子行不存在
     */
    public ApplyStateResponse state(Long userId, Long conversationId) {
        requireMember(conversationId, userId);
        ConversationEntity conversation = conversationMapper.selectById(conversationId);
        if (conversation == null) {
            throw notFound();
        }
        PostChatAnchor anchor = postService.chatAnchor(conversation.getPostId());
        ApplyStatus status = ApplyStatus.fromDb(conversation.getApplyStatus());
        return buildState(userId, conversation, anchor, status, LocalDateTime.now());
    }

    /**
     * 组装申请卡状态响应（提交 / 审批 / 查询三条路径共用同一口径）。
     *
     * @param userId       当前用户 ID（判断是否为发布者）
     * @param conversation 会话（已含本次动作后的状态）
     * @param anchor       帖子锚点（「需申请」开关）
     * @param status       卡片状态
     * @param now          计算入口可用性所用的当前时刻
     * @return {@link ApplyStateResponse} 卡片状态与两个入口可用性
     */
    private ApplyStateResponse buildState(Long userId, ConversationEntity conversation,
            PostChatAnchor anchor, ApplyStatus status, LocalDateTime now) {
        boolean owner = userId.equals(conversation.getOwnerId());

        LocalDateTime reapplyAt = null;
        boolean canApply = false;
        if (!owner && anchor.applyRequired()) {
            switch (status) {
                case NONE -> canApply = true;
                case PENDING -> {
                    reapplyAt = plusHours(conversation.getApplyAt(),
                            ChatLimits.APPLY_PENDING_REAPPLY_HOURS);
                    canApply = reapplyAt != null && !now.isBefore(reapplyAt);
                }
                case REJECTED -> {
                    reapplyAt = plusDays(conversation.getApplyDecidedAt(),
                            ChatLimits.APPLY_REJECT_COOLDOWN_DAYS);
                    canApply = reapplyAt != null && !now.isBefore(reapplyAt);
                }
                case APPROVED -> canApply = false;
                default -> throw new IllegalStateException("未覆盖的申请状态: " + status);
            }
        }
        boolean canViewContact = owner || !anchor.applyRequired()
                || status == ApplyStatus.APPROVED;
        return new ApplyStateResponse(conversation.getId(), anchor.applyRequired(),
                status.dbValue(), owner, canApply, canViewContact, toInstant(reapplyAt));
    }

    /**
     * 判断某用户对某帖子是否已获得联系方式可见授权（取号闸门用，R22 / R24）。
     *
     * <p>只认「该帖 + 该发起人」的会话且状态为已同意；无需申请的帖子不走本方法
     * （由调用方按帖子开关短路）。</p>
     *
     * @param postId 帖子 ID
     * @param userId 申请人 user_id
     * @return boolean true=已同意，可取号
     */
    public boolean hasApprovedAccess(Long postId, Long userId) {
        ConversationEntity conversation = conversationMapper.selectOne(
                new QueryWrapper<ConversationEntity>()
                        .eq("post_id", postId)
                        .eq("initiator_id", userId));
        return conversation != null
                && ApplyStatus.APPROVED.dbValue().equals(conversation.getApplyStatus());
    }

    /**
     * 加行锁读取会话并校验成员身份（R32）。
     *
     * @param conversationId 会话 ID
     * @param userId         当前用户 ID
     * @return {@link ConversationEntity} 加锁读到的会话
     * @throws BizException {@code 40305}，文案为「会话不存在或已不可访问」
     */
    private ConversationEntity lockAndRequireMember(Long conversationId, Long userId) {
        ConversationEntity conversation = conversationMapper.selectByIdForUpdate(conversationId);
        if (conversation == null || memberMapper.selectMember(conversationId, userId) == null) {
            throw notFound();
        }
        return conversation;
    }

    /**
     * 成员校验（读路径，不加锁）。
     *
     * @param conversationId 会话 ID
     * @param userId         当前用户 ID
     * @throws BizException {@code 40305} 非成员
     */
    private void requireMember(Long conversationId, Long userId) {
        if (memberMapper.selectMember(conversationId, userId) == null) {
            throw notFound();
        }
    }

    /**
     * 更新卡片状态与提交时刻。
     *
     * @param conversationId 会话 ID
     * @param status         目标状态
     * @param now            本次动作时刻
     */
    private void updateApplyState(Long conversationId, ApplyStatus status, LocalDateTime now) {
        ConversationEntity patch = new ConversationEntity();
        patch.setId(conversationId);
        patch.setApplyStatus(status.dbValue());
        patch.setApplyAt(now);
        if (status == ApplyStatus.APPROVED || status == ApplyStatus.REJECTED) {
            patch.setApplyDecidedAt(now);
        }
        conversationMapper.updateById(patch);
    }

    /**
     * 把同会话的联系事件渠道升级为「申请」（R31 / KTD11：不新增事件）。
     *
     * @param conversationId 会话 ID
     */
    private void upgradeContactEventChannel(Long conversationId) {
        contactEventMapper.update(null, new UpdateWrapper<ContactEventEntity>()
                .eq("conversation_id", conversationId)
                .set("channel_type", ContactChannel.APPLY));
    }

    /**
     * 断言距离上次动作已超出窗口，否则拒绝再次提交（R21）。
     *
     * @param since      上次动作时刻（可空=从未动作，直接放行）
     * @param amount     窗口长度
     * @param inHours    true=按小时计（重申窗口）；false=按天计（冷却期）
     * @throws BizException {@code 40001} 仍在窗口内
     */
    private void requireOutsideWindow(LocalDateTime since, int amount, boolean inHours) {
        if (since == null) {
            return;
        }
        LocalDateTime openAt = inHours ? since.plusHours(amount) : since.plusDays(amount);
        if (LocalDateTime.now().isBefore(openAt)) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
    }

    /**
     * 计算「时刻 + N 小时」，入参为空时返回 {@code null}。
     *
     * @param base   基准时刻（可空）
     * @param hours  小时数
     * @return {@link LocalDateTime} 结果；基准为空时 {@code null}
     */
    private LocalDateTime plusHours(LocalDateTime base, int hours) {
        return base == null ? null : base.plusHours(hours);
    }

    /**
     * 计算「时刻 + N 天」，入参为空时返回 {@code null}。
     *
     * @param base 基准时刻（可空）
     * @param days 天数
     * @return {@link LocalDateTime} 结果；基准为空时 {@code null}
     */
    private LocalDateTime plusDays(LocalDateTime base, int days) {
        return base == null ? null : base.plusDays(days);
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
