package com.s2s.server.contact.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.contact.entity.ReportEntity;
import org.apache.ibatis.annotations.Mapper;

/**
 * 举报 Mapper（映射表 {@code report}）。
 *
 * <p>只继承 {@link BaseMapper}：Batch1 只有「新增举报」一条写路径。
 * 举报的读取（运营处理队列）属上架前补齐的运营后台，不在 Batch1 范围
 * （说明文档 §2.7 裁剪表）。</p>
 */
@Mapper
public interface ReportMapper extends BaseMapper<ReportEntity> {
}
