package com.s2s.server.contact.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.contact.entity.ContactEventEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 联系事件 Mapper（映射表 {@code contact_event}）。
 *
 * <p>只继承 {@link BaseMapper} 复用通用 insert：写入路径单一（一行一事件，
 * 只增不改），批量聚合查询（每帖联系数）挂在 post 域的
 * {@code PostQueryMapper#countContactEvents}——那里是「我的发布」出数需求，
 * 属读侧聚合，不重复建第二处。</p>
 */
@Mapper
public interface ContactEventMapper extends BaseMapper<ContactEventEntity> {
}
