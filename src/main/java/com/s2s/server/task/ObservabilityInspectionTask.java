package com.s2s.server.task;

import com.s2s.server.common.constants.NfrObs;
import com.s2s.server.common.observability.RestartWindowEntity;
import com.s2s.server.common.observability.mapper.RestartWindowMapper;
import com.s2s.server.track.TrackPersistence;
import com.s2s.server.track.mapper.TrackMaintenanceMapper;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.YearMonth;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
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
 *   <li><b>T3 主看板 SQL 耗时</b>：读入镜像的清单文件
 *       {@code docs/architecture/dashboard_queries.sql}（§9.1.1），逐条在埋点库执行并计时，
 *       任一条超 {@link NfrObs#MIGRATION_DASHBOARD_SQL_SECONDS} 秒即写告警。判定对象 =
 *       <b>Q2 / Q3 / Q5 / Q6</b>；Q1 / Q4（Batch2 交付物）与 Q7（非 SQL 判据）记
 *       <b>N/A 并标注原因</b>；文件缺失/不可读记 <b>SKIP</b> —— 三种「不参与」严格区分，
 *       且<b>均不得记 PASS</b>（可观测 §9.1 的门禁纪律与编码规范 §7.4 同源：扫描面为空是
 *       SKIP 不是 PASS）。</li>
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

    /** Q2/Q5 里由巡检侧注入的重启窗口排除占位（可观测 §9.1.1 两段式注入）。 */
    private static final String WINDOW_PLACEHOLDER = "/* RESTART_WINDOWS_EXCLUSION */";

    /** 清单里的当月月表名占位（须替换为实际月表，如 {@code track_event_202610}）。 */
    private static final String MONTH_TABLE_PLACEHOLDER = "track_event_YYYYMM";

    /** T3 状态：文件缺失/不可读/未解析出条目——如实记 SKIP，不得记 PASS。 */
    private static final String STATUS_SKIP = "SKIP";

    /** T3 状态：已按清单逐条执行。 */
    private static final String STATUS_EXECUTED = "EXECUTED";

    /** 重启窗口时刻的格式化模式（固定模式，输出只含数字与分隔符）。 */
    private static final DateTimeFormatter WINDOW_TIMESTAMP =
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

    /** 重启窗口时刻的白名单形态：拼入 SQL 前的最后一道校验（防注入，编码规范 §6）。 */
    private static final Pattern WINDOW_TIMESTAMP_WHITELIST =
            Pattern.compile("^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$");

    /** 秒 → 毫秒换算因子（阈值常量以秒给出，比较前换算，不复制阈值字面量）。 */
    private static final int MILLIS_PER_SECOND = 1000;

    private final TrackMaintenanceMapper maintenanceMapper;

    /** 启动时间窗 Mapper（业务库）：Q2/Q5 的排除条件由巡检侧先取窗口再注入，不跨库 join。 */
    private final RestartWindowMapper restartWindowMapper;

    /** 主看板 SQL 清单路径（默认取运行镜像内路径，见 application.yml 同名属性）。 */
    private final String dashboardSqlPath;

    /** 计时时钟（生产用系统时钟；测试注入可控时钟以确定性验证「超阈值」判定）。 */
    private final Clock clock;

    /**
     * 构造巡检任务（Spring 注入用的主构造器）。
     *
     * @param trackPersistence     埋点库持久层入口（T1/T2/T3 全部取自埋点库）
     * @param restartWindowMapper  启动时间窗 Mapper（业务库；T3 的 Q2/Q5 两段式注入取窗口用）
     * @param dashboardSqlPath     主看板 SQL 清单路径（默认 = 运行镜像内
     *                             {@code /opt/s2s/observability/dashboard_queries.sql}）
     */
    @Autowired
    public ObservabilityInspectionTask(TrackPersistence trackPersistence,
            RestartWindowMapper restartWindowMapper,
            @Value("${s2s.observability.dashboard-sql-path:"
                    + "/opt/s2s/observability/dashboard_queries.sql}") String dashboardSqlPath) {
        this(trackPersistence.mapper(TrackMaintenanceMapper.class), restartWindowMapper,
                dashboardSqlPath, Clock.systemDefaultZone());
    }

    /**
     * 构造巡检任务（可注入 Mapper 与时钟，供测试确定性驱动 T3）。
     *
     * @param maintenanceMapper     埋点库维护 Mapper
     * @param restartWindowMapper   启动时间窗 Mapper（业务库）
     * @param dashboardSqlPath      主看板 SQL 清单路径
     * @param clock                 计时时钟（生产为系统时钟；测试传可控时钟）
     */
    ObservabilityInspectionTask(TrackMaintenanceMapper maintenanceMapper,
            RestartWindowMapper restartWindowMapper, String dashboardSqlPath, Clock clock) {
        this.maintenanceMapper = maintenanceMapper;
        this.restartWindowMapper = restartWindowMapper;
        this.dashboardSqlPath = dashboardSqlPath;
        this.clock = clock;
    }

    /**
     * 巡检可执行阈值（T1 两项 + T2 + T3），命中即写 ERROR 告警日志。
     *
     * @return void；命中阈值时记 ERROR，未命中记 INFO；T3 的执行/SKIP 状态随摘要一并记录
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

        DashboardInspection dashboard = inspectDashboardSql();
        hits.addAll(dashboard.hits());

        if (!hits.isEmpty()) {
            log.error("可观测巡检命中迁移阈值（可观测 §9.1：命中即启动迁移评估，动作次序见 §9.3）：{}",
                    hits);
        } else {
            log.info("可观测巡检完成：埋点行数={}、占盘={}GB、高位分钟数={}（窗口 {} 天，"
                            + "单分钟阈值 {}）；T3={}（已执行 {}，N/A {}，未能判定 {}），"
                            + "未命中 T1/T2/T3",
                    eventRows, storageGb, highVolumeMinutes, NfrObs.MIGRATION_WINDOW_DAYS,
                    perMinuteThreshold, dashboard.status(), dashboard.executed(),
                    dashboard.notApplicable(), dashboard.failed());
        }
    }

    /**
     * 执行 T3 判据：读主看板 SQL 清单，逐条在埋点库执行并计时（可观测 §9.1.1 / §9.1 T3）。
     *
     * <p>四种结果严格区分、且均不得记 PASS：</p>
     * <ul>
     *   <li><b>文件缺失/不可读/未解析出条目</b> → 记 {@link #STATUS_SKIP}；</li>
     *   <li><b>Q1/Q4/Q7</b>（Batch2 交付物 / 非 SQL 判据）→ 记 <b>N/A 并标注原因</b>；</li>
     *   <li><b>执行报错</b>（埋点库或当月月表不可用）→ 记入 {@code failed}，状态降为
     *       {@link #STATUS_SKIP} —— 判据未能判定，结论是「不知道」而非「通过」；</li>
     *   <li>其余条目逐条执行并计时，任一条超
     *       {@link NfrObs#MIGRATION_DASHBOARD_SQL_SECONDS} 秒即入 {@code hits}。</li>
     * </ul>
     *
     * <p><b>状态判据</b>：只要无任何条目真正完成判定（{@code executed} 为空），状态就是
     * {@link #STATUS_SKIP}。否则若「全部条目执行报错」（例如当月月表尚未建出）会把空
     * {@code executed} + 空 {@code hits} 误读成「未命中即通过」——正是「扫描面为空是 SKIP
     * 不是 PASS」要防的假绿。</p>
     *
     * @return {@link DashboardInspection} T3 结果（状态、已执行条目、N/A 条目、未能判定条目、命中项）
     */
    DashboardInspection inspectDashboardSql() {
        Path path = Path.of(dashboardSqlPath);
        if (!Files.isRegularFile(path)) {
            log.warn("可观测巡检：T3 记 SKIP——主看板 SQL 清单文件不存在（{}）；"
                    + "按「扫描面为空是 SKIP 不是 PASS」如实标注，不得记为通过", path);
            return new DashboardInspection(STATUS_SKIP, List.of(), List.of(), List.of(), List.of());
        }
        String content;
        try {
            content = Files.readString(path, StandardCharsets.UTF_8);
        } catch (IOException exception) {
            log.warn("可观测巡检：T3 记 SKIP——主看板 SQL 清单文件不可读（{}）", path, exception);
            return new DashboardInspection(STATUS_SKIP, List.of(), List.of(), List.of(), List.of());
        }
        List<DashboardSqlCatalog.Query> queries = DashboardSqlCatalog.parse(content).queries();
        if (queries.isEmpty()) {
            log.warn("可观测巡检：T3 记 SKIP——主看板 SQL 清单未解析出任何条目（{}）", path);
            return new DashboardInspection(STATUS_SKIP, List.of(), List.of(), List.of(), List.of());
        }

        // 两段式注入的可变片段在此一次性算好：窗口取自业务库（不跨库 join），月表取当月
        String windowExclusion = restartWindowExclusion();
        String monthTable = TrackTableNames.of(YearMonth.now(clock));
        List<String> executed = new ArrayList<>();
        List<String> notApplicable = new ArrayList<>();
        List<String> failed = new ArrayList<>();
        List<String> hits = new ArrayList<>();
        for (DashboardSqlCatalog.Query query : queries) {
            if (query.naReason() != null) {
                notApplicable.add("Q" + query.number() + " " + query.naReason());
                log.info("可观测巡检：T3 Q{} 记 {}（不参与本次判定，也不记为通过）",
                        query.number(), query.naReason());
                continue;
            }
            runDashboardQuery(query, windowExclusion, monthTable, executed, failed, hits);
        }
        if (!failed.isEmpty()) {
            log.warn("可观测巡检：T3 有 {} 条未能判定（结论是「不知道」，不是「通过」）：{}",
                    failed.size(), failed);
        }
        String status = executed.isEmpty() ? STATUS_SKIP : STATUS_EXECUTED;
        return new DashboardInspection(status, executed, notApplicable, failed, hits);
    }

    /**
     * 执行单条主看板 SQL 并计时，超阈值即记入命中项。
     *
     * <p>语句先替换两处占位（月表名、重启窗口排除子句），再经「仅允许单条 SELECT」兜底校验；
     * 计时口径 = 调用埋点库前后的时钟差。</p>
     *
     * @param query          条目
     * @param windowExclusion 重启窗口排除子句（无窗口时为空串）
     * @param monthTable     当月月表名
     * @param executed       已执行条目收集器（形如 {@code Q2}）
     * @param failed         未能判定条目收集器（执行报错；不得混入 executed，避免假绿）
     * @param hits           命中项收集器
     * @return void
     */
    private void runDashboardQuery(DashboardSqlCatalog.Query query, String windowExclusion,
            String monthTable, List<String> executed, List<String> failed, List<String> hits) {
        String sql = query.statement()
                .replace(MONTH_TABLE_PLACEHOLDER, monthTable)
                .replace(WINDOW_PLACEHOLDER, windowExclusion);
        if (!isSingleSelect(sql)) {
            log.warn("可观测巡检：T3 跳过 Q{}——清单语句不是单条 SELECT，拒绝执行（防篡改/防注入）",
                    query.number());
            failed.add("Q" + query.number() + " 非单条 SELECT，拒绝执行");
            return;
        }
        Instant start = clock.instant();
        try {
            maintenanceMapper.executeDashboardQuery(sql);
        } catch (DataAccessException exception) {
            log.error("可观测巡检：T3 Q{} 执行失败（埋点库或当月月表不可用），本次不计入耗时判定",
                    query.number(), exception);
            failed.add("Q" + query.number() + " " + exception.getClass().getSimpleName());
            return;
        }
        long elapsedMillis = Duration.between(start, clock.instant()).toMillis();
        executed.add("Q" + query.number());
        long thresholdMillis = NfrObs.MIGRATION_DASHBOARD_SQL_SECONDS * MILLIS_PER_SECOND;
        if (elapsedMillis > thresholdMillis) {
            hits.add("T3 主看板 SQL Q" + query.number() + " 单次执行 " + elapsedMillis + "ms > "
                    + NfrObs.MIGRATION_DASHBOARD_SQL_SECONDS + "s");
        }
    }

    /**
     * 组装 Q2/Q5 的重启窗口排除子句（两段式注入的注入侧，可观测 §9.1.1）。
     *
     * <p>窗口来自<b>业务库</b> {@code restart_window}（不跨库 join）；无有效窗口时返回空串
     * （等价于不排除，与 §6.1.1 分母口径一致）。每个时刻经
     * {@code yyyy-MM-dd HH:mm:ss} 白名单复校后才拼入——<b>禁把未校验输入拼进 SQL</b>
     * （编码规范 §6 SQL 注入防护）。</p>
     *
     * @return {@link String} 形如 {@code AND NOT ( (ts BETWEEN '…' AND '…') OR … )} 的子句；
     *         无有效窗口时为空串
     */
    private String restartWindowExclusion() {
        List<RestartWindowEntity> windows = restartWindowMapper.selectList(null);
        if (windows == null || windows.isEmpty()) {
            return "";
        }
        StringBuilder clause = new StringBuilder();
        for (RestartWindowEntity window : windows) {
            if (window == null || window.getStartAt() == null || window.getEndAt() == null) {
                continue;
            }
            String start = windowTimestamp(window.getStartAt());
            String end = windowTimestamp(window.getEndAt());
            if (start == null || end == null) {
                // 理论不可达：LocalDateTime 按固定模式格式化必过白名单；仍显式拒绝，防被改写
                log.warn("可观测巡检：T3 重启窗口时刻未通过白名单校验，已跳过该窗口");
                continue;
            }
            if (clause.length() == 0) {
                clause.append("AND NOT (");
            } else {
                clause.append(" OR");
            }
            clause.append(" (ts BETWEEN '").append(start).append("' AND '").append(end).append("')");
        }
        return clause.length() == 0 ? "" : clause.append(" )").toString();
    }

    /**
     * 把重启窗口时刻格式化为白名单允许的形态。
     *
     * @param moment 窗口时刻
     * @return {@link String} 形如 {@code 2026-10-10 06:00:00}；未过白名单时返回 {@code null}
     */
    private static String windowTimestamp(LocalDateTime moment) {
        String formatted = moment.format(WINDOW_TIMESTAMP);
        return WINDOW_TIMESTAMP_WHITELIST.matcher(formatted).matches() ? formatted : null;
    }

    /**
     * 判定语句是否为单条 SELECT（拼入 {@code ${sql}} 前的兜底：清单被改成非查询即拒执行）。
     *
     * @param sql 已替换占位符的语句
     * @return boolean；为 {@code true} 才允许执行
     */
    private static boolean isSingleSelect(String sql) {
        String normalized = sql.stripLeading().toLowerCase();
        return normalized.startsWith("select") && normalized.indexOf(';') < 0;
    }

    /**
     * T3 巡检结果（[148]）。
     *
     * @param status        见 {@link #STATUS_SKIP} / {@link #STATUS_EXECUTED}；无任何条目真正
     *                      完成判定（{@code executed} 为空）时为 {@link #STATUS_SKIP}
     * @param executed      已执行并计时的条目（形如 {@code Q2}）
     * @param notApplicable N/A 条目（含原因，形如 {@code Q1 N/A（Batch2 交付物…）}）
     * @param failed        未能判定的条目（执行报错；**不计入 executed**，否则会形成「未命中即通过」的假绿）
     * @param hits          命中 T3 阈值的告警项
     */
    record DashboardInspection(String status, List<String> executed, List<String> notApplicable,
            List<String> failed, List<String> hits) {
    }
}
