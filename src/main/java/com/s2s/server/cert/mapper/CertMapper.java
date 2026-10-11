package com.s2s.server.cert.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.cert.entity.CertEntity;

/**
 * {@code cert} 表数据访问接口（[149]）。
 *
 * <p>职责：为 {@link CertEntity} 提供 MyBatis-Plus 基础 CRUD。本域不新增自定义方法——
 * 简单 CRUD 用 BaseMapper（编码规范 §4.9「简单 CRUD 用 MyBatis-Plus，性能语句 XML + EXPLAIN」）。</p>
 *
 * <p>注册方式：由启动类 {@code @MapperScan("com.s2s.server.**.mapper")} 扫描注册。</p>
 *
 * <p>域边界（编码规范 §4.2）：仅 cert 域内 service 可注入本接口。</p>
 */
public interface CertMapper extends BaseMapper<CertEntity> {
}
