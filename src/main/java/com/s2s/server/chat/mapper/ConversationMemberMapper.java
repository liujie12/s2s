package com.s2s.server.chat.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.chat.entity.ConversationMemberEntity;
import org.apache.ibatis.annotations.Mapper;

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
}
