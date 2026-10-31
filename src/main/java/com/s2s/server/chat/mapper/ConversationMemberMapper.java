package com.s2s.server.chat.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.chat.entity.ConversationMemberEntity;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 会话成员 Mapper（映射表 {@code conversation_member}）。
 *
 * <p><b>只允许 insert 走 {@link BaseMapper}</b>；按复合主键的读取（成员校验）、
 * 已读水位推进、已推送标记复位都走自定义 XML（U3 / U4）——
 * {@code @TableId} 只标了 {@code conversation_id}，{@code updateById} 会误改同会话的
 * 另一位成员。</p>
 */
@Mapper
public interface ConversationMemberMapper extends BaseMapper<ConversationMemberEntity> {

    /**
     * 按复合主键读取一条成员行。
     *
     * <p>既是成员校验的判定依据（查不到即非成员 → {@code 40305}），也在 U4 用于取
     * 已读水位。查询走主键 {@code (conversation_id, user_id)}，无回表放大。</p>
     *
     * @param conversationId 会话 ID
     * @param userId         成员 user_id
     * @return {@link ConversationMemberEntity} 成员行；不是成员时 {@code null}
     */
    ConversationMemberEntity selectMember(@Param("conversationId") Long conversationId,
            @Param("userId") Long userId);

    /**
     * 推进已读水位并复位已推送标记（R10 / KTD7）。
     *
     * <p>水位取 {@code GREATEST(last_read_seq, 入参)}：已读只增不减，重复提交或乱序提交
     * 都不会把已读退回未读。{@code pushed_unread} 同时复位，使下一轮未读可以再推一次。</p>
     *
     * @param conversationId 会话 ID
     * @param userId         成员 user_id
     * @param lastReadSeq    本次推进到的最新序号
     * @return int 受影响行数（0 表示不是成员或会话已不存在）
     */
    int markRead(@Param("conversationId") Long conversationId,
            @Param("userId") Long userId,
            @Param("lastReadSeq") int lastReadSeq);
}
