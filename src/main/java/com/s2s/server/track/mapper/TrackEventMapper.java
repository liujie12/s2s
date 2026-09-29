package com.s2s.server.track.mapper;

import com.s2s.server.track.dto.TrackEventRow;
import java.util.List;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 埋点事件月表批量写入 Mapper（详设 §5.8 第 [7] 步）。
 *
 * <p><b>为什么是「无实体 + @Param + XML」</b>：埋点库无 entity（详设 §1.2 定案），且月表
 * 名按月变动（{@code track_event_YYYYMM}），列集合固定。故以纯接口 + 动态表名参数表达，
 * 不继承 {@code BaseMapper}（那会引入 MP 的单表映射假设，与动态表名冲突）。</p>
 *
 * <p><b>不经 {@code @MapperScan}</b>：本包 {@code com.s2s.server.track.mapper} 被启动类主扫描
 * 排除（否则会绑到业务库数据源），实例一律经
 * {@code com.s2s.server.track.TrackPersistence#mapper(Class)} 取得。分区承载关系由常驻门禁
 * {@code MapperScanCoverageTest} 守住；此处的 {@link Mapper} 注解仅作文档标记，不参与装配。</p>
 *
 * <p><b>SQL 形态纪律</b>（由 {@code TrackSqlFormGuardTest} 静态守门）：
 * {@code INSERT INTO <表> (列...) VALUES (...) ON DUPLICATE KEY UPDATE id = id}；
 * 严禁 {@code INSERT IGNORE}（会静默降级数据质量报错）；严禁 {@code props = VALUES(props)}
 * （会把重复行的 props 覆盖回同值、扩大写放大且违反「重复不更新」语义）；
 * {@code ts} 必须取客户端上报值（占位符 {@code #{e.ts}}），禁用 {@code NOW()}。</p>
 */
@Mapper
public interface TrackEventMapper {

    /**
     * 向指定月表批量写入事件（{@code ON DUPLICATE KEY UPDATE id = id}，去重靠唯一索引）。
     *
     * @param tableName 目标表名（月表 {@code track_event_YYYYMM} 或兜底表
     *        {@code track_event_fallback}；由 service 白名单校验后传入，XML 以 {@code ${}} 拼接）
     * @param events    待写入的落库行列表（非空；每行承载一事件的列值）
     * @param userId    触发用户 ID（登录态唯一来源；同批所有行共用）
     * @param deviceId  设备指纹（请求头 {@code X-Device-Id}；同批所有行共用，可空）
     * @return int 受影响行数（MySQL 对重复行返回 0、新行返回 1，故求和 = 实际入库事件数）
     */
    int batchInsert(@Param("tableName") String tableName,
            @Param("events") List<TrackEventRow> events,
            @Param("userId") Long userId,
            @Param("deviceId") String deviceId);
}
