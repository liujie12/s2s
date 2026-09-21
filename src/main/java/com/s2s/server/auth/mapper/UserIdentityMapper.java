package com.s2s.server.auth.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.auth.entity.UserIdentityEntity;

/**
 * {@code user_identity} 表数据访问接口（[123] U2）。
 *
 * <p>职责：为 {@link UserIdentityEntity} 提供 MyBatis-Plus 基础 CRUD。本单元不新增自定义方法
 * ——登录主路径的「按 {@code identity_hash} 等值查询命中唯一索引」由
 * {@link BaseMapper#selectOne} + {@code Wrapper} 条件在 service 层组装（U5 落地），
 * 无需为等值查询单独声明 mapper 方法。</p>
 *
 * <p>注册方式：由启动类 {@code @MapperScan("com.s2s.server.**.mapper")} 扫描注册。</p>
 *
 * <p>出处：详设 §7（数据访问）、编码规范 §4.2（分层与域边界）。</p>
 */
public interface UserIdentityMapper extends BaseMapper<UserIdentityEntity> {
}
