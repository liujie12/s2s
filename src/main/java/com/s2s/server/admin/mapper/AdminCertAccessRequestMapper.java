package com.s2s.server.admin.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.admin.entity.AdminCertAccessRequestEntity;
import java.util.List;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 认证敏感查看复核申请 Mapper（映射表 {@code admin_cert_access_request}；[153] B2-5）。
 *
 * <p>写路径（发起 / 复核）用 {@link BaseMapper}；后台列表的**分页查询**用自定义方法
 * ——本工程未注册 MyBatis-Plus 分页插件，故用显式 {@code LIMIT}/{@code OFFSET} 参数绑定
 * （SQL 见 {@code resources/mapper/AdminCertAccessRequestMapper.xml}）。</p>
 */
@Mapper
public interface AdminCertAccessRequestMapper extends BaseMapper<AdminCertAccessRequestEntity> {

    /**
     * 统计指定状态的复核申请条数（后台列表总数）。
     *
     * @param status 复核状态（{@code null}/空 → 不限，统计全部）
     * @return long 命中条数
     */
    long countByStatus(@Param("status") String status);

    /**
     * 按状态分页查询复核申请（按申请时间倒序 = 最新申请排前）。
     *
     * @param status 复核状态（{@code null}/空 → 不限）
     * @param offset 偏移量
     * @param limit  每页条数
     * @return {@link List} 当前页复核申请
     */
    List<AdminCertAccessRequestEntity> selectPageByStatus(@Param("status") String status,
            @Param("offset") int offset, @Param("limit") int limit);
}
