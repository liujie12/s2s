package com.s2s.server.auth.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.auth.entity.UserEntity;

/**
 * {@code user} 表数据访问接口（[123] U2）。
 *
 * <p>职责：为 {@link UserEntity} 提供 MyBatis-Plus 基础 CRUD。本单元（持久层最小设施）
 * <b>不新增自定义方法</b>——简单 CRUD 用 BaseMapper，性能语句留待后续域按详设 §7
 * 加 Mapper XML + EXPLAIN（编码规范 §4.9「简单 CRUD 用 MyBatis-Plus，性能语句 XML + EXPLAIN」）。</p>
 *
 * <p>注册方式：由启动类 {@code @MapperScan("com.s2s.server.**.mapper")} 扫描注册，
 * 本接口无需 {@code @Mapper} 注解（@MapperScan 默认扫描包下所有接口）。</p>
 *
 * <p>域边界（编码规范 §4.2）：仅 auth 域内 service 可注入本接口；跨域一律调
 * {@code auth} 域 service，禁跨域 mapper。</p>
 *
 * <p>出处：详设 §7（数据访问）、编码规范 §4.2（分层与域边界）、§4.9（数据访问）。</p>
 */
public interface UserMapper extends BaseMapper<UserEntity> {
}
