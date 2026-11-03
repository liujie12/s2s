package com.s2s.server.chat;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.admin.config.AdminConfigKeys;
import com.s2s.server.chat.dto.ConversationCreateRequest;
import com.s2s.server.chat.dto.ConversationCreateResponse;
import com.s2s.server.chat.dto.ConversationRemoveResponse;
import com.s2s.server.chat.entity.ConversationEntity;
import com.s2s.server.chat.entity.ConversationMemberEntity;
import com.s2s.server.chat.mapper.ConversationMapper;
import com.s2s.server.chat.mapper.ConversationMemberMapper;
import com.s2s.server.common.config.SystemConfigService;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitEntries;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import com.s2s.server.common.ratelimit.RateLimitTrack;
import com.s2s.server.common.ratelimit.RateLimiter;
import com.s2s.server.post.PostStatus;
import com.s2s.server.post.PostService;
import com.s2s.server.post.dto.PostChatAnchor;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 会话主链服务（V30 / 计划 U2）。
 *
 * <p>职责：提供「从详情页开启会话」的唯一入口——复用优先、额度受控、维护态可拦、
 * 非成员不可见。消息收发在 {@code ChatMessageService}（U3），列表与已读在
 * {@code ChatQueryService}（U4），本类只管「开会话」这一件事。</p>
 *
 * <p><b>门禁次序</b>（与计划 U2 一致）：维护开关 → 帖子可见性 → 自聊校验 →
 * 复用判定 → 每日新会话额度。额度放最后，是因为复用既有会话不应消耗额度；
 * 而幂等重放根本不会进入本方法（{@code IdempotencyInterceptor} 直接返回首次响应），
 * 故不需要在方法内再加一层去重。</p>
 */
@Service
public class ChatService {

    private final ConversationMapper conversationMapper;
    private final ConversationMemberMapper memberMapper;
    private final PostService postService;
    private final SystemConfigService systemConfigService;
    private final RateLimiter rateLimiter;

    /**
     * 构造会话服务。
     *
     * @param conversationMapper   会话持久层
     * @param memberMapper         会话成员持久层
     * @param postService          post 域服务（取会话锚点，跨域只调 service）
     * @param systemConfigService  系统配置（消息总开关）
     * @param rateLimiter          限频计数唯一执行处（每日新会话额度）
     */
    public ChatService(ConversationMapper conversationMapper,
            ConversationMemberMapper memberMapper,
            PostService postService,
            SystemConfigService systemConfigService,
            RateLimiter rateLimiter) {
        this.conversationMapper = conversationMapper;
        this.memberMapper = memberMapper;
        this.postService = postService;
        this.systemConfigService = systemConfigService;
        this.rateLimiter = rateLimiter;
    }

    /**
     * 开启或复用会话（{@code POST /conversations}）。
     *
     * <p>同一帖子与同一发起人全生命周期只有一条会话（{@code uk_post_initiator}）：
     * 命中既有会话时直接返回，不新建；若该会话已因 90 天无往来而从列表隐藏，
     * 把最后往来时间刷到当前时刻以恢复可见（KTD8：隐藏是查询条件，不是状态翻转）。</p>
     *
     * @param userId  当前登录用户 ID（控制器已保证非 null）
     * @param request 开会话入参（帖子 ID）
     * @return {@link ConversationCreateResponse}（会话 ID + 是否新建）
     * @throws BizException {@code 40305} 维护中 / {@code 41001} 帖子不可见 /
     *         {@code 40001} 与自己开会话 / {@code 42902} 当日新会话额度用尽
     */
    @Transactional
    public ConversationCreateResponse openConversation(Long userId,
            ConversationCreateRequest request) {
        requireMessageEnabled();

        PostChatAnchor anchor = postService.chatAnchor(request.postId());
        if (PostStatus.isGoneForOthers(anchor.status())) {
            // 与详情、取号同一口径：行不存在与对他人不可见同码，不泄露帖子状态
            throw BizException.of(ErrorCode.POST_GONE);
        }
        if (anchor.ownerId().equals(userId)) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        ConversationEntity existing = findExisting(anchor.postId(), userId);
        if (existing != null) {
            restoreVisibilityIfHidden(existing);
            restoreMemberVisibility(existing.getId(), userId);
            return new ConversationCreateResponse(existing.getId(), false);
        }

        ConversationEntity conversation = new ConversationEntity();
        conversation.setPostId(anchor.postId());
        conversation.setInitiatorId(userId);
        conversation.setOwnerId(anchor.ownerId());
        conversation.setApplyStatus(ApplyStatus.NONE.dbValue());
        try {
            conversationMapper.insert(conversation);
        } catch (DuplicateKeyException exception) {
            // 并发双击：另一请求刚插入同一 (post_id, initiator_id)，复用它的会话
            ConversationEntity raced = findExisting(anchor.postId(), userId);
            if (raced == null) {
                throw exception;
            }
            restoreVisibilityIfHidden(raced);
            restoreMemberVisibility(raced.getId(), userId);
            return new ConversationCreateResponse(raced.getId(), false);
        }

        insertMember(conversation.getId(), userId);
        insertMember(conversation.getId(), anchor.ownerId());

        consumeNewConversationQuota(userId);
        return new ConversationCreateResponse(conversation.getId(), true);
    }

    /**
     * 把会话从当前用户的消息列表删除（{@code DELETE /conversations/{id}}，V33）。
     *
     * <p><b>仅本人口径</b>：只置当前用户成员行的 {@code deleted_at}，对方列表不受影响；
     * 会话与消息仍保留（举报取证需要，与 PRD §7.4.2 / §9.7 一致）。删除同时把已读水位
     * 推到会话当前最大序号，避免「列表里看不到、未读却一直亮着」。</p>
     *
     * <p>恢复由两条链路负责：对方再发新消息（{@code ChatMessageService} 清空双方
     * {@code deleted_at}），或本人重新从详情页发起同一会话（{@link #openConversation}）。
     * 重复删除幂等。</p>
     *
     * @param userId         当前登录用户 ID（控制器已保证非 null）
     * @param conversationId 会话 ID
     * @return {@link ConversationRemoveResponse} 被移除的会话 ID
     * @throws BizException {@code 40305} 会话不存在或当前用户不是成员
     */
    @Transactional
    public ConversationRemoveResponse removeConversation(Long userId, Long conversationId) {
        ConversationMemberEntity member = memberMapper.selectMember(conversationId, userId);
        ConversationEntity conversation = conversationMapper.selectById(conversationId);
        if (member == null || conversation == null) {
            // 与成员校验同一响应：不泄露会话存在性（R32）
            throw BizException.of(ErrorCode.NO_PERMISSION, ChatCopy.CONVERSATION_NOT_FOUND);
        }
        int lastSeq = conversation.getLastSeq() == null ? 0 : conversation.getLastSeq();
        memberMapper.hideConversation(conversationId, userId, lastSeq);
        return new ConversationRemoveResponse(conversationId);
    }

    /**
     * 断言消息功能未被运营关闭（R30 / KTD4）。
     *
     * <p>开关缺行按开启（{@link SystemConfigService#isOnOrAbsent(String)}）：一次配置漏种
     * 不应该让聊天整体静默变只读。</p>
     *
     * @throws BizException {@code 40305}，文案为维护提示
     */
    public void requireMessageEnabled() {
        if (!systemConfigService.isOnOrAbsent(AdminConfigKeys.MESSAGE_ENABLED)) {
            throw BizException.of(ErrorCode.NO_PERMISSION, ChatCopy.MAINTENANCE);
        }
    }

    /**
     * 按「帖子 + 发起人」查既有会话。
     *
     * @param postId      帖子 ID
     * @param initiatorId 发起人 user_id
     * @return {@link ConversationEntity} 既有会话；不存在时 {@code null}
     */
    private ConversationEntity findExisting(Long postId, Long initiatorId) {
        return conversationMapper.selectOne(new QueryWrapper<ConversationEntity>()
                .eq("post_id", postId)
                .eq("initiator_id", initiatorId));
    }

    /**
     * 90 天无往来的会话再次发起时恢复可见（KTD8）。
     *
     * <p>只刷新「已隐藏」的会话：对活跃会话改 {@code last_message_at} 会把它顶到列表最前，
     * 破坏「按最后一条消息时间倒序」的口径。</p>
     *
     * @param conversation 命中复用的会话（原地更新并落库）
     */
    private void restoreVisibilityIfHidden(ConversationEntity conversation) {
        LocalDateTime now = LocalDateTime.now();
        LocalDateTime hiddenBefore = now.minusDays(ChatLimits.CONVERSATION_HIDE_AFTER_DAYS);
        LocalDateTime last = conversation.getLastMessageAt();
        if (last != null && last.isAfter(hiddenBefore)) {
            return;
        }
        conversation.setLastMessageAt(now);
        conversationMapper.updateById(conversation);
    }

    /**
     * 恢复本人对被删会话的可见性（V33：重新发起同一会话时调用）。
     *
     * <p>只清自己那一行，不触碰对方；未删除时该更新命中 0 行，天然幂等。</p>
     *
     * @param conversationId 会话 ID
     * @param userId         当前登录用户 ID
     */
    private void restoreMemberVisibility(Long conversationId, Long userId) {
        memberMapper.restoreVisibility(conversationId, userId);
    }

    /**
     * 写入一条会话成员（已读水位与已推送标记走库内默认值）。
     *
     * @param conversationId 会话 ID
     * @param memberId       成员 user_id
     */
    private void insertMember(Long conversationId, Long memberId) {
        ConversationMemberEntity member = new ConversationMemberEntity();
        member.setConversationId(conversationId);
        member.setUserId(memberId);
        memberMapper.insert(member);
    }

    /**
     * 消耗一次「每日新会话」额度（R27 / K3）。
     *
     * <p>只在确认新建之后推进计数：复用既有会话不计入额度。计数仍只经
     * {@link RateLimiter}（唯一计数处）；超限时把 {@code 42902} 换成会话域专用文案
     * （KTD4），错误码与 {@code Retry-After} 语义不变。</p>
     *
     * @param userId 当前登录用户 ID
     * @throws BizException {@code 42902}（needRetryAfter，带剩余秒数）
     */
    private void consumeNewConversationQuota(Long userId) {
        LocalDate today = RateLimitKeys.today();
        RateLimitEntries.RateLimitDimensions dimensions =
                RateLimitEntries.RateLimitDimensions.of(userId, null, "", today);
        List<RateLimiter.RateLimitEntry> entries = new ArrayList<>(
                RateLimitEntries.forTrack(RateLimitTrack.CHAT_NEW_UID, dimensions));
        if (entries.isEmpty()) {
            // 账号级轨在 userId 非空时恒有条目；空列表说明轨定义被改坏，不能静默放行
            throw new IllegalStateException("每日新会话额度未产生计数条目：账号轨应恒有条目");
        }
        try {
            rateLimiter.incrementAndCheck(entries);
        } catch (BizException exception) {
            if (exception.getErrorCode() == RateLimitThresholds.CHAT_NEW_OVERFLOW) {
                throw BizException.ofRetryAfter(exception.getErrorCode(),
                        exception.getRetryAfterSeconds(), ChatCopy.NEW_CONVERSATION_LIMIT);
            }
            throw exception;
        }
    }
}
