package com.s2s.server.task;

import com.s2s.server.common.constants.NfrRetention;
import com.s2s.server.track.TrackPersistence;
import com.s2s.server.track.mapper.TrackMaintenanceMapper;
import java.time.LocalDate;
import java.time.YearMonth;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 埋点月表预建与清理任务（[129] P4；架构 §8 任务 2/3；详设 §6 任务 #2/#3）。
 *
 * <p><b>预建为什么必须存在</b>（架构 §8 口径说明第 1 条）：按月分表意味着跨月的第一次写入
 * 会找不到表，{@code INSERT} 直接报错、当天埋点全丢。故每月 25 日提前建下月表，留出失败重试余量。</p>
 *
 * <p><b>两条形态硬纪律</b>（数据库设计 §3.16.1 尾段 / §6.5）：</p>
 * <ol>
 *   <li>预建用 {@code CREATE TABLE ... LIKE}——{@code LIKE} 连索引（含 {@code uk_event_dedup}）
 *       一起复制；逐列拼 DDL 会漏索引，导致下月去重<b>静默失效</b>；</li>
 *   <li>清理用整表 {@code DROP}——对千万行表做 {@code DELETE} 会把 256MB buffer pool 与
 *       binlog 一起打满（这是「按月分表」这条设计的存在理由）。</li>
 * </ol>
 *
 * <p><b>清理判定用「整月都过期」而非「月初过期」</b>：月表承载整月数据，只要该月月末仍落在
 * 保留期内，就还有未过期数据，整表不可删。故判定式为
 * {@code month.atEndOfMonth() < today - NFR天}。</p>
 *
 * <p>本任务经 {@link TrackPersistence} 取埋点库 Mapper（埋点库为独立 database，
 * 不经 {@code @MapperScan}，理由见 {@code TrackPersistenceConfig}）。</p>
 */
@Component
public class TrackMonthTableTask {

    private static final Logger log = LoggerFactory.getLogger(TrackMonthTableTask.class);

    /**
     * 预建调度：每月 25 日 03:00（六段 cron；详设 §6 任务 #2 频率列「每月 25 日」）。
     */
    private static final String CRON_PREBUILD = "0 0 3 25 * *";

    /**
     * 清理调度：每日 03:20（六段 cron；详设 §6 任务 #3 频率列「每日」）。
     */
    private static final String CRON_CLEANUP = "0 20 3 * * *";

    private final TrackMaintenanceMapper maintenanceMapper;

    /**
     * 构造埋点月表维护任务。
     *
     * @param trackPersistence 埋点库持久层入口（本任务据此取得维护 Mapper）
     */
    public TrackMonthTableTask(TrackPersistence trackPersistence) {
        this.maintenanceMapper = trackPersistence.mapper(TrackMaintenanceMapper.class);
    }

    /**
     * 预建下月月表（以当月表为结构模板）。
     *
     * <p>当月表缺失时（例如首次部署即跨月）无法复制结构，本任务记 WARN 跳过——
     * 由运维介入建表，而不是凭空拼一份 DDL（那会与 {@code LIKE} 的索引复制保证相悖）。</p>
     *
     * @return void；成功时记 INFO，模板缺失时记 WARN
     */
    @Scheduled(cron = CRON_PREBUILD)
    public void prebuildNextMonthTable() {
        YearMonth currentMonth = YearMonth.now();
        String templateTable = TrackTableNames.of(currentMonth);
        String nextTable = TrackTableNames.of(currentMonth.plusMonths(1));
        try {
            maintenanceMapper.createTableLike(nextTable, templateTable);
            log.info("埋点月表预建完成：{}（结构模板 {}）", nextTable, templateTable);
        } catch (DataAccessException exception) {
            log.warn("埋点月表预建失败：目标 {}，结构模板 {} 不可用——"
                            + "请人工确认当月月表是否存在（预建必须走 CREATE TABLE ... LIKE，"
                            + "不得逐列拼 DDL，否则会漏掉 uk_event_dedup）",
                    nextTable, templateTable, exception);
        }
    }

    /**
     * 删除整月数据均已超出保留期的月表。
     *
     * @return void；无过期表时不产生日志；表名非月表形态时记 WARN 并跳过
     */
    @Scheduled(cron = CRON_CLEANUP)
    public void dropExpiredMonthTables() {
        LocalDate cutoff = LocalDate.now().minusDays(NfrRetention.TRACK_EVENT_RETENTION_DAYS);
        List<String> tables = maintenanceMapper.listMonthTables();
        for (String table : tables) {
            YearMonth month = TrackTableNames.parse(table);
            if (month == null) {
                log.warn("埋点库内存在不符合命名口径的表，已跳过（不猜测其归属）：{}", table);
                continue;
            }
            if (month.atEndOfMonth().isBefore(cutoff)) {
                maintenanceMapper.dropTable(table);
                log.info("埋点月表清理：DROP {}（整月数据早于 {}, 保留 {} 天）",
                        table, cutoff, NfrRetention.TRACK_EVENT_RETENTION_DAYS);
            }
        }
    }
}
