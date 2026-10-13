package com.s2s.server.common.audit.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.common.audit.AuditLogEntity;
import com.s2s.server.common.audit.dto.AuditLogFilter;
import java.util.List;
import org.apache.ibatis.annotations.Mapper;

/**
 * 审计留痕 Mapper（映射表 {@code audit_log}）。
 *
 * <p>继承了 {@link BaseMapper} 复用通用 insert —— 审计的<b>写入</b>路径单一
 * （只增不改不删，180 天后由定时任务 #4 清理）。</p>
 *
 * <p><b>查询</b>（[153] B2-5 审计查询接口）走本接口的两个自定义方法
 * （{@code countByFilter} / {@code selectPageByFilter}，SQL 见
 * {@code resources/mapper/AuditLogQueryMapper.xml}）：不引 MyBatis-Plus 分页插件
 * （本工程未注册 {@code PaginationInnerInterceptor}，{@code selectPage} 会静默不生效），
 * 改用显式 {@code LIMIT}/{@code OFFSET} 参数绑定，避免「以为分页了其实全表」的假绿。</p>
 *
 * <p>包路径须以 {@code .mapper} 结尾方能被 {@code @MapperScan("com.s2s.server.**.mapper")}
 * 扫到，故落 {@code common/audit/mapper}。</p>
 */
@Mapper
public interface AuditLogMapper extends BaseMapper<AuditLogEntity> {

    /**
     * 按过滤条件统计命中条数。
     *
     * @param filter 过滤条件（分页参数在本方法中不使用）
     * @return long 命中总数
     */
    long countByFilter(AuditLogFilter filter);

    /**
     * 按过滤条件分页查询（按操作时间倒序）。
     *
     * @param filter 过滤条件（含 {@code limit}/{@code offset}）
     * @return {@link List} 当前页审计行（映射 {@link AuditLogEntity}）
     */
    List<AuditLogEntity> selectPageByFilter(AuditLogFilter filter);
}
