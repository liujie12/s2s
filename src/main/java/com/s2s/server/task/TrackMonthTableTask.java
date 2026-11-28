package com.s2s.server.task;

import com.s2s.server.common.constants.NfrRetention;
import com.s2s.server.track.TrackPersistence;
import com.s2s.server.track.dto.TrackFallbackRow;
import com.s2s.server.track.mapper.TrackFallbackMapper;
import com.s2s.server.track.mapper.TrackMaintenanceMapper;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.YearMonth;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.dao.DataAccessException;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 埋点月表预建、清理与兜底搬运任务（[129] P4；架构 §8 任务 2/3；详设 §6 任务 #2/#3；
 * 数据库设计 §3.17）。
 *
 * <p><b>预建为什么必须存在</b>（架构 §8 口径说明第 1 条）：按月分表意味着跨月的第一次写入
 * 会找不到表，{@code INSERT} 直接报错、当天埋点全丢。故每月 25 日提前建下月表，留出失败重试余量。</p>
 *
 * <p><b>兜底搬运为什么必须存在</b>（数据库设计 §3.17）：月表缺失时写入降级到
 * {@code track_event_fallback}，该表是缓冲不是终点——必须每分钟按 {@code ts} 搬进正确月表
 * 并删除已搬行，否则兜底数据永远进不了指标，重传重复也会一直留在缓冲里。去重只在终点发生：
 * 兜底表刻意无唯一索引，搬运 SQL 用 {@code ON DUPLICATE KEY UPDATE id = id}，由月表
 * {@code uk_event_dedup} 一次性消化重复；顺序固定为「先插月表、后删兜底行」，中途失败只触发
 * 下次重搬（插入幂等、删除重试），不丢行。</p>
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

    /**
     * 月表兜底确保调度：每日 03:10（DEF-04）。
     *
     * <p>预建只在每月 25 日跑一次；新机/新库若从未跑到该窗口（例如 11-05 与 11-13 两次全新部署），
     * 当月表会一直不存在，全部埋点降级兜底。故每日再确保一次「当月 + 下月」，
     * 成本仅为两次 {@code information_schema} 查询与必要的 {@code CREATE TABLE ... LIKE}。</p>
     */
    private static final String CRON_ENSURE = "0 10 3 * * *";

    /**
     * 兜底搬运调度间隔：每分钟一次（数据库设计 §3.17「后台任务每分钟按 ts 搬运」）。
     */
    private static final long RELAY_INTERVAL_MILLIS = 60_000L;

    /**
     * 单批搬运上限：控制单条 {@code INSERT ... SELECT} 体积，剩余行由下一分钟继续搬。
     */
    private static final int RELAY_BATCH_SIZE = 500;

    /** MySQL「表不存在」错误码（区分「月表未预建」与真实写入故障）。 */
    private static final int MYSQL_ERR_NO_SUCH_TABLE = 1146;

    private final TrackMaintenanceMapper maintenanceMapper;

    /** 兜底表搬运 Mapper（月表缺失期间缓冲行的唯一清空通道）。 */
    private final TrackFallbackMapper fallbackMapper;

    /** 已告警过的缺失月表（同一进程内同类 WARN 只打一次，避免每分钟刷屏）。 */
    private final Set<String> missingTableWarned = ConcurrentHashMap.newKeySet();

    /**
     * 构造埋点月表维护任务。
     *
     * @param trackPersistence 埋点库持久层入口（本任务据此取得维护与搬运 Mapper）
     */
    public TrackMonthTableTask(TrackPersistence trackPersistence) {
        this.maintenanceMapper = trackPersistence.mapper(TrackMaintenanceMapper.class);
        this.fallbackMapper = trackPersistence.mapper(TrackFallbackMapper.class);
    }

    /**
     * 预建下月月表（每月 25 日 03:00；DEF-04 起改为「确保当月 + 下月」的超集语义）。
     *
     * <p>结构模板不再假定「当月表一定存在」：从库内既有月表中取最新一张作模板，
     * 因此新部署跨月、当月表缺失时也能自愈，而不是只能等运维人工建表。</p>
     *
     * @return void；成功建表时记 INFO，库内无任何合法月表时记 ERROR
     */
    @Scheduled(cron = CRON_PREBUILD)
    public void prebuildNextMonthTable() {
        ensureMonthTables("每月预建");
    }

    /**
     * 启动兜底：进程/容器启动后立即确保「当月 + 下月」月表存在（DEF-04）。
     *
     * <p>失败只记 WARN 不阻塞启动——埋点写入本身已有兜底表降级路径，
     * 不能因为一次建表失败让整个应用起不来；每日兜底会继续重试。</p>
     *
     * @return void
     */
    @EventListener(ApplicationReadyEvent.class)
    public void ensureMonthTablesOnStartup() {
        try {
            ensureMonthTables("启动兜底");
        } catch (RuntimeException exception) {
            log.warn("埋点月表启动兜底失败（不阻塞启动，等待每日兜底重试）", exception);
        }
    }

    /**
     * 每日兜底：确保「当月 + 下月」月表存在（DEF-04；每日 03:10）。
     *
     * @return void；失败记 ERROR，不向外抛（调度器下一日继续）
     */
    @Scheduled(cron = CRON_ENSURE)
    public void ensureMonthTablesDaily() {
        try {
            ensureMonthTables("每日兜底");
        } catch (RuntimeException exception) {
            log.error("埋点月表每日兜底失败", exception);
        }
    }

    /**
     * 确保当月与下月月表存在：缺哪张补哪张，结构一律复制库内最新月表。
     *
     * <p>月份按 <b>UTC</b> 计算：事件归属月由 {@code ts}（客户端 UTC 采集时刻）决定，
     * 用本地时区会在每月最后 8 小时（东八区）把「下月」算晚一个月。</p>
     *
     * @param trigger 触发来源（仅用于日志区分：启动兜底 / 每日兜底 / 每月预建）
     * @return void；库内没有任何合法月表时记 ERROR 并返回
     */
    private void ensureMonthTables(String trigger) {
        List<String> existing = maintenanceMapper.listMonthTables();
        String template = null;
        for (String table : existing) {
            if (TrackTableNames.parse(table) != null) {
                template = table;
            }
        }
        if (template == null) {
            log.error("埋点月表兜底确保（{}）失败：库内没有任何合法月表可作结构模板", trigger);
            return;
        }

        YearMonth current = YearMonth.now(ZoneOffset.UTC);
        for (YearMonth month : List.of(current, current.plusMonths(1))) {
            String target = TrackTableNames.of(month);
            if (existing.contains(target)) {
                continue;
            }
            maintenanceMapper.createTableLike(target, template);
            log.info("埋点月表兜底确保（{}）：已建 {}（结构模板 {}）", trigger, target, template);
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

    /**
     * 把兜底表积压行按 {@code ts} 搬入对应月表并删除已搬行。
     *
     * <p>顺序固定为「先插月表、后删兜底行」：插入语句带 {@code ON DUPLICATE KEY UPDATE id = id}，
     * 重复搬入不会产生重复行；若进程在删除前中断，下次重搬仍幂等。月表不存在（1146）时
     * 保留该组行等待下次（同一进程内每张缺失表只打一次 WARN，避免每分钟刷屏）。</p>
     *
     * @return void；无可搬运行时不产生任何调用与日志
     */
    @Scheduled(fixedDelay = RELAY_INTERVAL_MILLIS)
    public void relayFallbackRows() {
        List<TrackFallbackRow> pending = fallbackMapper.selectPending(RELAY_BATCH_SIZE);
        if (pending.isEmpty()) {
            return;
        }

        Map<String, List<Long>> idsByTable = new LinkedHashMap<>();
        for (TrackFallbackRow row : pending) {
            String table = TrackTableNames.of(YearMonth.from(row.getTs()));
            idsByTable.computeIfAbsent(table, key -> new ArrayList<>()).add(row.getId());
        }

        for (Map.Entry<String, List<Long>> entry : idsByTable.entrySet()) {
            String table = entry.getKey();
            List<Long> ids = entry.getValue();
            try {
                int inserted = fallbackMapper.relayToMonth(table, ids);
                fallbackMapper.deleteByIds(ids);
                missingTableWarned.remove(table);
                log.info("埋点兜底搬运完成：{} 行 → {}（净新增 {}）", ids.size(), table, inserted);
            } catch (DataAccessException exception) {
                if (isTableMissing(exception)) {
                    if (missingTableWarned.add(table)) {
                        log.warn("埋点兜底搬运跳过：月表 {} 不存在，{} 行保留待下次"
                                + "（同类告警本进程只打一次）", table, ids.size());
                    }
                    continue;
                }
                log.error("埋点兜底搬运失败：目标 {}，{} 行保留待下次", table, ids.size(), exception);
            }
        }
    }

    /**
     * 判定数据访问异常是否为「表不存在（MySQL 1146）」。
     *
     * @param exception 数据访问异常（可能含多层 cause）
     * @return boolean {@code true} 表示异常链中存在 errorCode 1146 的 {@link SQLException}
     */
    private static boolean isTableMissing(DataAccessException exception) {
        Throwable cause = exception;
        while (cause != null) {
            if (cause instanceof SQLException sqlException
                    && sqlException.getErrorCode() == MYSQL_ERR_NO_SUCH_TABLE) {
                return true;
            }
            cause = cause.getCause();
        }
        return false;
    }
}
