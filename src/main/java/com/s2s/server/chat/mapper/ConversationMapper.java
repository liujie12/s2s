package com.s2s.server.chat.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.chat.entity.ConversationEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 会话 Mapper（映射表 {@code conversation}）。
 *
 * <p>只继承 {@link BaseMapper}：会话行的加锁自增（{@code last_seq}）与列表聚合同
 * 会话列 {@code conversation_member}，分别由 {@code MessageMapper} 与
 * {@code ConversationMapper} 的自定义 XML 承载（U3 / U4），本接口不重复建第二处。</p>
 */
@Mapper
public interface ConversationMapper extends BaseMapper<ConversationEntity> {
}
