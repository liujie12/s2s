package com.s2s.server.track.mapper;

import com.s2s.server.track.dto.TrackFallbackRow;
import java.util.List;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 埋点兜底表搬运 Mapper（月表损坏/缺失时的缓冲清理）。
 *
 * <p><b>为什么与 {@link TrackEventMapper} 分开</b>：写入 Mapper 只负责“把事件放进某张表”，
 * 形态被 {@code TrackSqlFormGuardTest} 冻结；本 Mapper 只负责“把兜底行搬到月表”，
 * 两者调用方与风险面不同（一个是请求线程，一个是定时任务），分开后各自可独立守门。</p>
 *
 * <p><b>去重发生在月表</b>：兜底表刻意不建 {@code uk_event_dedup}（数据库设计 §3.17），
 * 搬运 SQL 用 {@code ON DUPLICATE KEY UPDATE id = id} 写月表，由月表唯一索引消化
 * 兜底期间积累的重复。搬运顺序固定为「先插月表、后删兜底行」，中途失败只会导致下次重搬
 * （插入幂等、删除重试），不会丢行。</p>
 */
@Mapper
public interface TrackFallbackMapper {

    /**
     * 取一批待搬运的兜底行（只要 id 与 ts）。
     *
     * @param limit 单批上限（任务侧常量，避免一次搬运过大）
     * @return {@link List} 按 id 升序的待搬运行；空表时返回空列表
     */
    List<TrackFallbackRow> selectPending(@Param("limit") int limit);

    /**
     * 把指定兜底行按库内 {@code INSERT ... SELECT} 搬入目标月表（重复行由唯一索引消化）。
     *
     * @param tableName 目标月表名（由任务侧按 {@code TrackTableNames} 生成，非用户输入）
     * @param ids       本批兜底行 ID（非空）
     * @return int 受影响行数（新行 1、重复行 0；仅用于日志，不参与删除判断）
     */
    int relayToMonth(@Param("tableName") String tableName, @Param("ids") List<Long> ids);

    /**
     * 删除已成功搬入月表的兜底行。
     *
     * @param ids 已搬运行 ID（非空）
     * @return int 删除行数
     */
    int deleteByIds(@Param("ids") List<Long> ids);
}
