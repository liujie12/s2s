package com.s2s.server.post.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.post.entity.PostCertDeclarationEntity;

/**
 * {@code post_cert_declaration} 表数据访问接口（V22 新表）。
 *
 * <p>职责：为帖级凭证声明提供 MyBatis-Plus 基础 CRUD。一帖一证由 {@code uk_post}
 * 唯一约束保证，服务侧只在「先查后写」之外依赖该约束兜底并发重复写入。</p>
 */
public interface PostCertDeclarationMapper extends BaseMapper<PostCertDeclarationEntity> {
}
