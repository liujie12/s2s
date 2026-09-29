package com.s2s.server.task;

import com.s2s.server.common.constants.NfrObs;
import com.s2s.server.track.TrackPersistence;
import com.s2s.server.track.mapper.TrackMaintenanceMapper;
import java.time.LocalDateTime;
import java.time.YearMonth;
import java.util.ArrayList;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 可观测性阈值巡检任务（[129] P4；架构 §8 任务 8；详设 §6 任务 #8；阈值源可观测 §9.1）。
 *
 * <p><b>为什么这条任务不可省</b>（可观测 §9.1 尾段）：阈值写得再具体，没有执行者也只是文档里
 * 的字。本任务每周执行一次，任一命中即写告警日志（ERROR 级——迁移是需人工介入的事件，
 * 不是可自愈的降级）。</p>
 *
 * <p><b>四项检查与当前可执行性</b>：</p>
 * <ol>
 *   <li><b>T1 行数</b>：埋点月表行数合计 &gt; {@link NfrObs#MIGRATION_TRACK_ROWS}；</li>
 *   <li><b>T1 占盘</b>：埋点库占盘 &gt; {@link NfrObs#MIGRATION_TRACK_STORAGE_GB} GB
 *       （只量埋点库，不用 {@code df}——§9.1 明写，{@code df} 会在埋点只占 2GB 时误报）；</li>
 *   <li><b>T2 写入 QPS</b>：近 {@link NfrObs#MIGRATION_WINDOW_DAYS} 天内「单分钟事件数超过
 *       {@link NfrObs#MIGRATION_TRACK_QPS} × 60」的分钟数 ≥
 *       {@link NfrObs#MIGRATION_HIGH_VOLUME_MINUTES}（取持续高位而非峰值，避免一次活动误触发）；</li>
 *   <li><b>T3 主看板 SQL 耗时</b>：<b>当前不可执行</b>——可观测 §9.1.1 明确「七条主看板 SQL
 *       本身是 Batch1 交付物，须落在 docs/ 或 scripts/ 下的单一文件内」，而该文件至今未交付，
 *       无判定对象。本任务如实记 WARN 标注「未执行」（<b>不记为通过</b>——可观测 §9.1 的门禁
 *       纪律与编码规范 §7.4 同源：扫描面为空是 SKIP 不是 PASS），缺口登记见说明文档 §2.9。</li>
 * </ol>
 *
 * <p>调度频率取详设 §6 任务列「每周」；具体时刻取周一 06:00（业务低峰）。</p>
 */
@Component
public class ObservabilityInspectionTask {

    private static final Logger log = LoggerFactory.getLogger(ObservabilityInspectionTask.class);

    /**
     * 调度表达式：每周一 06:00（六段 cron；详设 §6 任务 #8 频率列「每周」）。
     */
    private static final String CRON_WEEKLY = "0 0 6 * * MON";

    private final TrackMaintenanceMapper maintenanceMapper;

    /**
     * 构造巡检任务。
     *
     * @param trackPersistence 埋点库持久层入口（巡检三项指标全部取自埋点库）
     */
    public ObservabilityInspectionTask(TrackPersistence trackPersistence) {
        this.maintenanceMapper = trackPersistence.mapper(TrackMaintenanceMapper.class);
    }

    /**
     * 巡检三项可执行阈值（T1 两项 + T2），命中即写 ERROR 告警日志。
     *
     * @return void；命中阈值时记 ERROR，未命中记 INFO，T3 恒记 WARN（未执行）
     */
    @Scheduled(cron = CRON_WEEKLY)
    public void inspectMigrationThresholds() {
        List<String> hits = new ArrayList<>();

        Long eventRows = maintenanceMapper.countEventRows();
        if (eventRows != null && eventRows > NfrObs.MIGRATION_TRACK_ROWS) {
            hits.add("T1 埋点行数 " + eventRows + " > " + NfrObs.MIGRATION_TRACK_ROWS);
        }
        Double storageGb = maintenanceMapper.storageGb();
        if (storageGb != null && storageGb > NfrObs.MIGRATION_TRACK_STORAGE_GB) {
            hits.add("T1 埋点库占盘 " + storageGb + "GB > " + NfrObs.MIGRATION_TRACK_STORAGE_GB + "GB");
        }

        long perMinuteThreshold = NfrObs.MIGRATION_TRACK_QPS * 60;
        LocalDateTime since = LocalDateTime.now().minusDays(NfrObs.MIGRATION_WINDOW_DAYS);
        Long highVolumeMinutes = null;
        try {
            highVolumeMinutes = maintenanceMapper.countHighVolumeMinutes(
                    TrackTableNames.of(YearMonth.now()), since, perMinuteThreshold);
        } catch (DataAccessException exception) {
            // 当月月表不存在（首次部署当月或预建未及）——不能当成「QPS 正常」
            log.warn("可观测巡检：T2 未执行——当月埋点月表不可用（{}），无法统计高位分钟数",
                    TrackTableNames.of(YearMonth.now()), exception);
        }
        if (highVolumeMinutes != null && highVolumeMinutes >= NfrObs.MIGRATION_HIGH_VOLUME_MINUTES) {
            hits.add("T2 高位分钟数 " + highVolumeMinutes + " >= " + NfrObs.MIGRATION_HIGH_VOLUME_MINUTES);
        }

        log.warn("可观测巡检：T3 未执行——主看板 SQL 清单（可观测 §9.1.1 的七条）尚未作为交付物"
                + "落地，无判定对象；按「扫描面为空是 SKIP 不是 PASS」如实标注，不得记为通过"
                + "（缺口见说明文档 §2.9）");

        if (!hits.isEmpty()) {
            log.error("可观测巡检命中迁移阈值（可观测 §9.1：命中即启动迁移评估，动作次序见 §9.3）：{}",
                    hits);
        } else {
            log.info("可观测巡检完成：埋点行数={}、占盘={}GB、高位分钟数={}（窗口 {} 天，"
                            + "单分钟阈值 {}），未命中 T1/T2",
                    eventRows, storageGb, highVolumeMinutes, NfrObs.MIGRATION_WINDOW_DAYS,
                    perMinuteThreshold);
        }
    }
}
