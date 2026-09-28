package com.s2s.server.common.observability.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.common.observability.RestartWindowEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 启动时间窗 Mapper（映射表 {@code restart_window}）。
 *
 * <p>只继承 {@link BaseMapper} 复用通用 insert——写入路径单一（应用启动时写一行，
 * 只增不改不删），无需自定义 SQL 与 XML。</p>
 *
 * <p>包路径须以 {@code .mapper} 结尾方能被
 * {@code @MapperScan("com.s2s.server.**.mapper")} 扫到，故落
 * {@code common/observability/mapper}。本条不是风格偏好，是启动期硬约束：
 * {@code @MapperScan} 一旦存在，mybatis-spring-boot-autoconfigure 的自动扫描就会被其
 * {@code @ConditionalOnMissingBean(MapperScannerConfigurer)} 关掉，{@code @Mapper}
 * 注解自身不会注册 bean（见 {@code AuditLogMapper} 类注释），由常驻门禁
 * {@code MapperScanCoverageTest} 守住。</p>
 */
@Mapper
public interface RestartWindowMapper extends BaseMapper<RestartWindowEntity> {
}
