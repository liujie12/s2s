package com.s2s.server.category.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.category.entity.SystemConfigEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 系统配置 Mapper（[124]）。
 *
 * <p>继承 {@link BaseMapper}，复用通用 CRUD；本域仅读不写。</p>
 */
@Mapper
public interface SystemConfigMapper extends BaseMapper<SystemConfigEntity> {
}
