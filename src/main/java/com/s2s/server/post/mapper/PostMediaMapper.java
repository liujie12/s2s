package com.s2s.server.post.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.post.entity.PostMediaEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 帖子媒体 Mapper（[125]）。
 *
 * <p>继承 {@link BaseMapper}，复用 MyBatis-Plus 通用 CRUD；孤儿 media 清理扫描
 * 由 [129] 定时任务按 {@code idx_audit_status_created} 索引执行。</p>
 */
@Mapper
public interface PostMediaMapper extends BaseMapper<PostMediaEntity> {
}
