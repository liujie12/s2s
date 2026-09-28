package com.s2s.server.common.audit.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.common.audit.AuditLogEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 审计留痕 Mapper（映射表 {@code audit_log}）。
 *
 * <p>只继承 {@link BaseMapper} 复用通用 insert——审计的写入路径单一
 * （只增不改不删，180 天后由定时任务 #4 清理），无需自定义 SQL。</p>
 *
 * <p>包路径须以 {@code .mapper} 结尾方能被
 * {@code @MapperScan("com.s2s.server.**.mapper")} 扫到，故落
 * {@code common/audit/mapper}。本条不是风格偏好，是启动期硬约束：{@code @MapperScan}
 * 一旦存在，mybatis-spring-boot-autoconfigure 的自动扫描就会被其
 * {@code @ConditionalOnMissingBean(MapperScannerConfigurer)} 关掉，{@code @Mapper}
 * 注解自身不会注册 bean——[128] code review 实测确证，本接口原落在
 * {@code common.audit} 时扫不到，会让注入它的 {@code AuditLogWriter} 在启动期失败。
 * 由常驻门禁 {@code MapperScanCoverageTest} 守住。</p>
 */
@Mapper
public interface AuditLogMapper extends BaseMapper<AuditLogEntity> {
}
