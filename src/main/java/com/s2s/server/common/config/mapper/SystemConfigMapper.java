package com.s2s.server.common.config.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.common.config.SystemConfigEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 系统配置 Mapper（[124] 引入，[127] 迁至 common）。
 *
 * <p>继承 {@link BaseMapper}，复用通用 CRUD；系统配置只读不写（运营改配置走数据库）。</p>
 *
 * <p>包路径须以 {@code .mapper} 结尾方能被
 * {@code @MapperScan("com.s2s.server.**.mapper")} 扫到，故落
 * {@code common/config/mapper}。</p>
 */
@Mapper
public interface SystemConfigMapper extends BaseMapper<SystemConfigEntity> {
}
