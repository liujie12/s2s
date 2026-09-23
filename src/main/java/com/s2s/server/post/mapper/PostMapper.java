package com.s2s.server.post.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.post.entity.PostEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 发布信息 Mapper（[125]）。
 *
 * <p>继承 {@link BaseMapper}，复用 MyBatis-Plus 通用 CRUD；性能语句（如
 * {@code /map/pins} 覆盖索引查询）留待 [126] 按详设 §5.4.2 加 XML + EXPLAIN。</p>
 */
@Mapper
public interface PostMapper extends BaseMapper<PostEntity> {
}
