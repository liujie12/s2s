package com.s2s.server.ops.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.ops.entity.TempCategoryStatEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 临时类目判定快照 Mapper（映射表 {@code temp_category_stat}；[153] B2-5 §9.10.2）。
 *
 * <p>只继承 {@link BaseMapper}：1:1 快照表，按主键读写。</p>
 */
@Mapper
public interface TempCategoryStatMapper extends BaseMapper<TempCategoryStatEntity> {
}
