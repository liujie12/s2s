package com.s2s.server.chat.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.chat.entity.MessageEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 消息 Mapper（映射表 {@code message}）。
 *
 * <p>{@link BaseMapper} 承载单行写入；会话行加锁取号（{@code last_seq} 自增）、
 * 消息分页与增量查询、未读计数走自定义 XML（U3 / U4）——这些语句需要显式
 * {@code FOR UPDATE} 或联表条件，不放进通用 CRUD。</p>
 */
@Mapper
public interface MessageMapper extends BaseMapper<MessageEntity> {
}
