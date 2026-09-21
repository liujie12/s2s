package com.s2s.server.auth.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.auth.entity.DeviceEntity;

/**
 * {@code device} 表数据访问接口（[123] U2）。
 *
 * <p>职责：为 {@link DeviceEntity} 提供 MyBatis-Plus 基础 CRUD。本单元不新增自定义方法
 * ——「按 {@code fingerprint} 唯一命中」与「更新 {@code push_token/platform/last_active_at}」
 * 由 service 层用 BaseMapper + {@code Wrapper} 组装（U5 落地），无需单独声明方法。</p>
 *
 * <p>注册方式：由启动类 {@code @MapperScan("com.s2s.server.**.mapper")} 扫描注册。</p>
 *
 * <p>出处：详设 §7（数据访问）、编码规范 §4.2（分层与域边界）。</p>
 */
public interface DeviceMapper extends BaseMapper<DeviceEntity> {
}
