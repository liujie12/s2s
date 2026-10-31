package com.s2s.server.chat.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.chat.entity.MessageEntity;
import java.util.List;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 消息 Mapper（映射表 {@code message}）。
 *
 * <p>{@link BaseMapper} 承载单行写入；会话行加锁取号（{@code last_seq} 自增）在
 * {@link ConversationMapper#selectByIdForUpdate(Long)}，消息分页与增量查询、未读计数
 * 走自定义 XML（U3 / U4）——这些语句需要联表条件与显式排序，不放进通用 CRUD。</p>
 */
@Mapper
public interface MessageMapper extends BaseMapper<MessageEntity> {

    /**
     * 统计「对方最后一条文本之后、我方发出的文本消息」条数（R26 / KTD3 的额度口径）。
     *
     * <p>只数 {@code type = 'text'}：申请卡与联系方式卡不计入未回复额度（R26）。
     * 对方从未发过文本时以 {@code 0} 为下界，即我方发出的全部文本都计入。</p>
     *
     * @param conversationId 会话 ID
     * @param senderId       当前发送者 user_id（只数本人发出的）
     * @return int 连续未获回复的文本条数（用于与 {@code ChatLimits.UNREPLIED_TEXT_LIMIT} 比较）
     */
    int countUnrepliedText(@Param("conversationId") Long conversationId,
            @Param("senderId") Long senderId);

    /**
     * 翻历史：取 {@code beforeSeq} 之前（不含）的一页消息，按 seq 倒序。
     *
     * <p>倒序取一页再由 service 翻转成正序：直接正序 + OFFSET 在长会话里翻到越深处越慢，
     * 且并发写入会让同一 OFFSET 指向不同行。</p>
     *
     * @param conversationId 会话 ID
     * @param userId         当前用户（过滤 {@code visible_to}：联系方式卡只对被同意人可见）
     * @param beforeSeq      游标（可空；空=从最新一条开始）
     * @param limit          每页条数（service 已钳制）
     * @return {@link List} 消息行（seq 倒序）
     */
    List<MessageEntity> selectBefore(@Param("conversationId") Long conversationId,
            @Param("userId") Long userId,
            @Param("beforeSeq") Integer beforeSeq,
            @Param("limit") int limit);

    /**
     * 增量拉取：取 {@code afterSeq} 之后（不含）的一页消息，按 seq 正序。
     *
     * @param conversationId 会话 ID
     * @param userId         当前用户（过滤 {@code visible_to}）
     * @param afterSeq       已持有的最大序号
     * @param limit          每页条数（service 已钳制）
     * @return {@link List} 消息行（seq 正序）
     */
    List<MessageEntity> selectAfter(@Param("conversationId") Long conversationId,
            @Param("userId") Long userId,
            @Param("afterSeq") int afterSeq,
            @Param("limit") int limit);
}
