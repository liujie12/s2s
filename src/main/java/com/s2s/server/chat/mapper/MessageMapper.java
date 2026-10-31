package com.s2s.server.chat.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.chat.entity.MessageEntity;
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
}
