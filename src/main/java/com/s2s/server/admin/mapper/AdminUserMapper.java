package com.s2s.server.admin.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.admin.entity.AdminUserEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 后台账号 Mapper（映射表 {@code admin_user}；[153] B2-5）。
 *
 * <p>只继承 {@link BaseMapper} 复用通用 CRUD —— 后台账号的读写形态是常规
 * 单表按 {@code username} 查（{@code QueryWrapper} 表达），无需自定义 SQL。</p>
 *
 * <p>包路径须以 {@code .mapper} 结尾方能被 {@code @MapperScan("com.s2s.server.**.mapper")}
 * 扫到（同 {@code AuditLogMapper} 的启动期硬约束）。</p>
 */
@Mapper
public interface AdminUserMapper extends BaseMapper<AdminUserEntity> {
}
