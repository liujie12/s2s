package com.s2s.server.chat;

import static com.s2s.server.common.jdbc.JdbcRowValues.toInstant;
import static com.s2s.server.common.jdbc.JdbcRowValues.toInteger;
import static com.s2s.server.common.jdbc.JdbcRowValues.toLong;

import com.s2s.server.chat.dto.ConversationItem;
import com.s2s.server.chat.dto.ConversationPageResponse;
import com.s2s.server.chat.dto.MessageItem;
import com.s2s.server.chat.dto.MessagePageResponse;
import com.s2s.server.chat.dto.ReadResult;
import com.s2s.server.chat.entity.ConversationEntity;
import com.s2s.server.chat.entity.ConversationMemberEntity;
import com.s2s.server.chat.entity.MessageEntity;
import com.s2s.server.chat.mapper.ConversationMapper;
import com.s2s.server.chat.mapper.ConversationMemberMapper;
import com.s2s.server.chat.mapper.MessageMapper;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.post.PostStatus;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 会话读取服务（V30 / 计划 U4）。
 *
 * <p>职责：会话列表、消息分页 / 增量拉取、置已读。三条链路都先做成员校验（R32）：
 * 非成员与不存在返回同一响应，不泄露会话存在性。</p>
 *
 * <p><b>隐藏窗口是查询条件</b>（KTD8）：列表以 {@code last_message_at} 的下界过滤，
 * 不写状态、不做定时任务；新的往来写入后会话自然重新可见。</p>
 *
 * <p><b>未读不在这里算总数</b>：本类只给会话行一个布尔红点，总数由
 * {@code UnreadSummaryService}（U5）唯一产出，避免两处口径漂移。</p>
 */
@Service
public class ChatQueryService {

    private final ConversationMapper conversationMapper;
    private final ConversationMemberMapper memberMapper;
    private final MessageMapper messageMapper;

    /**
     * 构造会话读取服务。
     *
     * @param conversationMapper 会话持久层（列表与隐藏窗口下界）
     * @param memberMapper       会话成员持久层（成员校验与已读水位）
     * @param messageMapper      消息持久层（分页与增量）
     */
    public ChatQueryService(ConversationMapper conversationMapper,
            ConversationMemberMapper memberMapper,
            MessageMapper messageMapper) {
        this.conversationMapper = conversationMapper;
        this.memberMapper = memberMapper;
        this.messageMapper = messageMapper;
    }

    /**
     * 会话列表（{@code GET /conversations}，R3 / R4）。
     *
     * <p>分页参数越界即钳制：{@code page < 1} 按 1，{@code page_size} 缺省取
     * {@link ChatLimits#CONVERSATION_PAGE_DEFAULT_SIZE}、超上限按
     * {@link ChatLimits#CONVERSATION_PAGE_MAX_SIZE}（避免一次拉全量）。</p>
     *
     * @param userId   当前登录用户 ID
     * @param page     页码（可空）
     * @param pageSize 每页条数（可空）
     * @return {@link ConversationPageResponse} 当前页 + 总数
     */
    public ConversationPageResponse listConversations(Long userId, Integer page, Integer pageSize) {
        int resolvedPage = page == null || page < 1 ? 1 : page;
        int resolvedPageSize = clampPageSize(pageSize);

        LocalDateTime visibleSince =
                LocalDateTime.now().minusDays(ChatLimits.CONVERSATION_HIDE_AFTER_DAYS);
        long total = conversationMapper.countForUser(userId, visibleSince);
        List<Map<String, Object>> rows = conversationMapper.selectPageForUser(userId, visibleSince,
                (resolvedPage - 1) * resolvedPageSize, resolvedPageSize);

        List<ConversationItem> items = new ArrayList<>(rows.size());
        for (Map<String, Object> row : rows) {
            items.add(new ConversationItem(
                    toLong(row.get("conversation_id")),
                    toLong(row.get("post_id")),
                    (String) row.get("post_title"),
                    PostStatus.isGoneForOthers((String) row.get("post_status")),
                    toLong(row.get("peer_id")),
                    (String) row.get("peer_nickname"),
                    (String) row.get("peer_avatar_url"),
                    (String) row.get("last_message_type"),
                    (String) row.get("last_message_preview"),
                    toInstant(row.get("last_message_at")),
                    Integer.valueOf(1).equals(toInteger(row.get("unread_flag"))),
                    (String) row.get("apply_status")));
        }
        return new ConversationPageResponse(items, total, resolvedPage, resolvedPageSize);
    }

    /**
     * 会话内消息（{@code GET /conversations/{id}/messages}，R6 / R10）。
     *
     * <p>两种取法互斥：带 {@code after_seq} 走增量（只返回游标之后、正序），
     * 否则走翻历史（{@code before_seq} 之前、倒序取一页后翻转成正序）。
     * 两者同时传视为参数非法，避免客户端拿到语义含糊的结果。</p>
     *
     * @param userId         当前登录用户 ID
     * @param conversationId 会话 ID
     * @param beforeSeq      翻历史游标（可空）
     * @param afterSeq       增量游标（可空）
     * @param pageSize       每页条数（可空）
     * @return {@link MessagePageResponse} 正序消息 + 是否还有更多
     * @throws BizException {@code 40001} 两个游标同时传入；{@code 40305} 非成员
     */
    public MessagePageResponse listMessages(Long userId, Long conversationId, Integer beforeSeq,
            Integer afterSeq, Integer pageSize) {
        if (beforeSeq != null && afterSeq != null) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        requireMember(conversationId, userId);

        int limit = clampMessagePageSize(pageSize);
        // 多取一条用于判断 hasMore，避免再发一次 COUNT
        int probe = limit + 1;

        List<MessageEntity> rows;
        boolean hasMore;
        if (afterSeq != null) {
            rows = messageMapper.selectAfter(conversationId, userId, afterSeq, probe);
            hasMore = rows.size() > limit;
            rows = hasMore ? new ArrayList<>(rows.subList(0, limit)) : rows;
        } else {
            rows = new ArrayList<>(messageMapper.selectBefore(conversationId, userId, beforeSeq,
                    probe));
            hasMore = rows.size() > limit;
            if (hasMore) {
                rows = new ArrayList<>(rows.subList(0, limit));
            }
            // 历史方向倒序取页，翻转成正序返回，客户端无需按请求方向切渲染顺序
            Collections.reverse(rows);
        }

        List<MessageItem> items = new ArrayList<>(rows.size());
        for (MessageEntity message : rows) {
            items.add(new MessageItem(message.getId(), message.getSeq(), message.getSenderId(),
                    message.getType(), message.getContent(), toInstant(message.getCreatedAt())));
        }
        return new MessagePageResponse(items, hasMore);
    }

    /**
     * 置已读（{@code POST /conversations/{id}/read}，R10）。
     *
     * <p>一次把水位推到会话当前最大序号——打开会话即全部已读，不受滚动位置影响；
     * 无论滚动到哪里，未读都归零。</p>
     *
     * @param userId         当前登录用户 ID
     * @param conversationId 会话 ID
     * @return {@link ReadResult} 推进后的水位
     * @throws BizException {@code 40305} 非成员或会话不存在
     */
    @Transactional
    public ReadResult markRead(Long userId, Long conversationId) {
        requireMember(conversationId, userId);
        ConversationEntity conversation = conversationMapper.selectById(conversationId);
        if (conversation == null) {
            throw notFound();
        }
        int lastSeq = conversation.getLastSeq() == null ? 0 : conversation.getLastSeq();
        int updated = memberMapper.markRead(conversationId, userId, lastSeq);
        if (updated == 0) {
            // 成员校验刚通过却更新不到行：成员行被并发删除（账号注销链路），按不可访问处理
            throw notFound();
        }
        return new ReadResult(lastSeq);
    }

    /**
     * 断言当前用户是会话成员（R32）。
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

    /**
     * 钳制会话列表分页大小。
     *
     * @param pageSize 入参（可空）
     * @return int 落在 [{@code CONVERSATION_PAGE_DEFAULT_SIZE},
     *         {@code CONVERSATION_PAGE_MAX_SIZE}] 内的页大小
     */
    private int clampPageSize(Integer pageSize) {
        if (pageSize == null || pageSize < 1) {
            return ChatLimits.CONVERSATION_PAGE_DEFAULT_SIZE;
        }
        return Math.min(pageSize, ChatLimits.CONVERSATION_PAGE_MAX_SIZE);
    }

    /**
     * 钳制消息分页大小。
     *
     * @param pageSize 入参（可空）
     * @return int 落在 [{@code MESSAGE_PAGE_DEFAULT_SIZE}, {@code MESSAGE_PAGE_MAX_SIZE}] 内的页大小
     */
    private int clampMessagePageSize(Integer pageSize) {
        if (pageSize == null || pageSize < 1) {
            return ChatLimits.MESSAGE_PAGE_DEFAULT_SIZE;
        }
        return Math.min(pageSize, ChatLimits.MESSAGE_PAGE_MAX_SIZE);
    }
}
