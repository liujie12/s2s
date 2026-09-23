package com.s2s.server.category.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.category.entity.CategoryEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 分类树 Mapper（[124]）。
 *
 * <p>继承 {@link BaseMapper}，复用 MyBatis-Plus 通用 CRUD；本域仅读不写，
 * 无自定义 SQL（编码规范 §4.9「简单 CRUD 用 MyBatis-Plus」）。</p>
 */
@Mapper
public interface CategoryMapper extends BaseMapper<CategoryEntity> {
}
