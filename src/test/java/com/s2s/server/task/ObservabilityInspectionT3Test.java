package com.s2s.server.task;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import com.s2s.server.common.observability.RestartWindowEntity;
import com.s2s.server.common.observability.mapper.RestartWindowMapper;
import com.s2s.server.track.mapper.TrackMaintenanceMapper;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.mockito.ArgumentCaptor;
import org.springframework.dao.QueryTimeoutException;

/**
 * T3 主看板 SQL 巡检接线测试（[148]；《可观测性架构方案》§9.1 T3 / §9.1.1）。
 *
 * <p><b>为什么这几种情形必须各有一条</b>：T3 的失效形态都很安静——</p>
 * <ul>
 *   <li><b>文件缺失记成 PASS</b>：镜像漏拷清单时，普通任务会「无判定对象」照样报「未命中」，
 *       看板上表现为绿灯，而 T3 其实一次没跑；本类钉死「缺失 → SKIP 且不碰数据源」。</li>
 *   <li><b>N/A 与 SKIP 混为一谈</b>：Q1/Q4/Q7 是「Batch1 结构上不参与」，与「文件没读到」
 *       是两回事；混记就再也分不清「没数据」还是「没接线」。</li>
 *   <li><b>占位未替换 / 月表名未换</b>：SQL 会语法错或命中错误的月表，而错在「判定对象」上，
 *       比错在断言上更难发现。</li>
 *   <li><b>阈值判定方向写反</b>：超 10 秒才命中，恰好 10 秒不算命中——边界方向错了会整天告警
 *       或永不告警。</li>
 * </ul>
 *
 * <p>纯单元测试：Mapper 以 Mockito 替身注入；时间由可控 {@link Clock} 驱动，
 * 不连库、不 sleep。</p>
 */
class ObservabilityInspectionT3Test {

    /** 覆盖七条的测试夹具：Q1/Q4 无 SQL（Batch2）、Q7 无 SQL（非 SQL 判据），Q2/Q3/Q5/Q6 可执行。 */
    private static final String FIXTURE = String.join("\n",
            "-- 主看板 SQL 清单（测试夹具）",
            "-- Q1 · 轴① 首次联系触发率 —— **Batch2 交付物（Batch1 不参与 T3，记 N/A）**",
            "-- 说明：示例 SQL 在注释里，不应被当成可执行语句",
            "--       SELECT 1 FROM track_event_YYYYMM;",
            "-- Q2 · 轴② 图层切换成功率",
            "SELECT COUNT(*) FROM track_event_YYYYMM WHERE event_name = 'layer_switch' "
                    + "/* RESTART_WINDOWS_EXCLUSION */;",
            "-- Q3 · 轴③ 完整发布率",
            "SELECT COUNT(*) FROM track_event_YYYYMM WHERE event_name = 'post_published';",
            "-- Q4 · 轴① 两项反向哨兵 —— **Batch2 交付物（Batch1 不参与 T3，记 N/A）**",
            "-- Q5 · 图层切换 P95 耗时",
            "SELECT MAX(1) FROM track_event_YYYYMM WHERE event_name = 'layer_switch' "
                    + "/* RESTART_WINDOWS_EXCLUSION */;",
            "-- Q6 · 四段和校验不过的事件数与占比",
            "SELECT COUNT(*) FROM track_event_YYYYMM;",
            "-- Q7 · dropped_count 队列溢出监控 —— **非 SQL 判据（日志扫描）**",
            "-- 无 SQL 判定对象");

    /** 夹具写盘用的临时目录。 */
    @TempDir
    Path tempDir;

    /** 埋点库维护 Mapper 替身。 */
    private TrackMaintenanceMapper maintenanceMapper;

    /** 启动时间窗 Mapper 替身（业务库）。 */
    private RestartWindowMapper restartWindowMapper;

    /**
     * 装配替身：默认无重启窗口（等价于不排除）。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        maintenanceMapper = mock(TrackMaintenanceMapper.class);
        restartWindowMapper = mock(RestartWindowMapper.class);
        when(restartWindowMapper.selectList(any())).thenReturn(List.of());
    }

    /**
     * 文件缺失 → T3 记 SKIP，且不触碰任何数据源（SKIP 不是 PASS）。
     *
     * @return void；断言失败即「镜像漏拷清单」会被误报为通过
     */
    @Test
    @DisplayName("文件缺失 → SKIP（不记 PASS），且不执行任何 SQL、不读业务库")
    void missingFileIsSkipped() {
        ObservabilityInspectionTask task = newTask(
                tempDir.resolve("not-there.sql").toString(), fixedClock());

        ObservabilityInspectionTask.DashboardInspection result = task.inspectDashboardSql();

        assertThat(result.status()).isEqualTo("SKIP");
        assertThat(result.executed()).isEmpty();
        assertThat(result.notApplicable()).isEmpty();
        assertThat(result.hits()).isEmpty();
        verifyNoInteractions(maintenanceMapper);
        verifyNoInteractions(restartWindowMapper);
    }

    /**
     * 含 N/A 条目 → Q1/Q4/Q7 跳过并各自标注原因，Q2/Q3/Q5/Q6 逐条执行。
     *
     * @throws IOException 夹具写盘失败时抛出
     * @return void；断言失败即 N/A 被误执行或与 SKIP 混记
     */
    @Test
    @DisplayName("含 N/A 条目 → Q1/Q4（Batch2）与 Q7（非 SQL）跳过并标注，Q2/Q3/Q5/Q6 执行")
    void notApplicableEntriesAreSkippedAndLabelled() throws IOException {
        ObservabilityInspectionTask task = newTask(writeFixture(FIXTURE), fixedClock());

        ObservabilityInspectionTask.DashboardInspection result = task.inspectDashboardSql();

        assertThat(result.status()).isEqualTo("EXECUTED");
        assertThat(result.executed()).containsExactly("Q2", "Q3", "Q5", "Q6");
        assertThat(result.notApplicable())
                .hasSize(3)
                .satisfiesExactly(
                        label -> assertThat(label).contains("Q1").contains("Batch2"),
                        label -> assertThat(label).contains("Q4").contains("Batch2"),
                        label -> assertThat(label).contains("Q7").contains("非 SQL"));
        verify(maintenanceMapper, times(4)).executeDashboardQuery(anyString());
    }

    /**
     * 月表名占位替换为当月月表（按注入时钟取「当月」）。
     *
     * @throws IOException 夹具写盘失败时抛出
     * @return void；断言失败即语句会打到错误的月表
     */
    @Test
    @DisplayName("月表名替换：track_event_YYYYMM → 当月月表（注入时钟 2026-10）")
    void monthTableNameReplacedWithCurrentMonth() throws IOException {
        ObservabilityInspectionTask task = newTask(writeFixture(FIXTURE), fixedClock());

        task.inspectDashboardSql();

        assertThat(capturedSql())
                .isNotEmpty()
                .allSatisfy(sql -> {
                    assertThat(sql).doesNotContain("track_event_YYYYMM");
                    assertThat(sql).contains("track_event_202610");
                });
    }

    /**
     * 空重启窗口 → 占位替换为空串（等价于不排除，与 §6.1.1 分母口径一致）。
     *
     * @throws IOException 夹具写盘失败时抛出
     * @return void；断言失败即空窗口被拼成非法子句
     */
    @Test
    @DisplayName("占位替换·空窗口 → 替换为空串（不产生 BETWEEN 子句）")
    void emptyRestartWindowLeavesNoExclusion() throws IOException {
        ObservabilityInspectionTask task = newTask(writeFixture(FIXTURE), fixedClock());

        task.inspectDashboardSql();

        List<String> windowQueries = capturedSql().stream()
                .filter(sql -> sql.contains("layer_switch"))
                .toList();
        assertThat(windowQueries).hasSize(2);
        assertThat(windowQueries).allSatisfy(sql -> {
            assertThat(sql).doesNotContain("RESTART_WINDOWS_EXCLUSION");
            assertThat(sql).doesNotContain("BETWEEN");
        });
    }

    /**
     * 多重启窗口 → 逐窗注入 {@code BETWEEN} 子句（值经白名单校验后拼入）。
     *
     * @throws IOException 夹具写盘失败时抛出
     * @return void；断言失败即重启预热期未被排除（P95 会被污染）
     */
    @Test
    @DisplayName("占位替换·多窗口 → 逐窗注入 BETWEEN（取业务库 restart_window，不跨库 join）")
    void multipleRestartWindowsInjectBetweenClauses() throws IOException {
        when(restartWindowMapper.selectList(any())).thenReturn(List.of(
                window(LocalDateTime.of(2026, 10, 1, 1, 0, 0), LocalDateTime.of(2026, 10, 1, 1, 5, 0)),
                window(LocalDateTime.of(2026, 10, 3, 12, 0, 0), LocalDateTime.of(2026, 10, 3, 12, 5, 0))));
        ObservabilityInspectionTask task = newTask(writeFixture(FIXTURE), fixedClock());

        task.inspectDashboardSql();

        List<String> windowQueries = capturedSql().stream()
                .filter(sql -> sql.contains("layer_switch"))
                .toList();
        assertThat(windowQueries).hasSize(2);
        assertThat(windowQueries).allSatisfy(sql -> {
            assertThat(sql).doesNotContain("RESTART_WINDOWS_EXCLUSION");
            assertThat(sql).contains("'2026-10-01 01:00:00'").contains("'2026-10-01 01:05:00'");
            assertThat(sql).contains("'2026-10-03 12:00:00'").contains("'2026-10-03 12:05:00'");
        });
    }

    /**
     * 超阈值 → 每条超时的 SQL 各记一条 T3 告警（阈值取常量 = 10s）。
     *
     * @throws IOException 夹具写盘失败时抛出
     * @return void；断言失败即超过 10 秒仍不告警
     */
    @Test
    @DisplayName("超阈值（每条 11s > 10s）→ 四条均入告警")
    void overThresholdQueryRaisesHit() throws IOException {
        ObservabilityInspectionTask task = newTask(
                writeFixture(FIXTURE), new SteppingClock(Duration.ofSeconds(11)));

        ObservabilityInspectionTask.DashboardInspection result = task.inspectDashboardSql();

        assertThat(result.executed()).containsExactly("Q2", "Q3", "Q5", "Q6");
        assertThat(result.hits()).hasSize(4);
        assertThat(result.hits()).allSatisfy(hit -> assertThat(hit).contains("T3"));
        assertThat(result.hits().get(0)).contains("Q2").contains("11000ms");
    }

    /**
     * 边界：恰好 10 秒不算命中（判据为「超 10 秒」，非「达到」）。
     *
     * @throws IOException 夹具写盘失败时抛出
     * @return void；断言失败即边界方向写反（恰好 10s 会天天误告警）
     */
    @Test
    @DisplayName("边界：恰好 10s 不告警（判据是「超 10 秒」）")
    void exactlyAtThresholdDoesNotAlert() throws IOException {
        ObservabilityInspectionTask task = newTask(
                writeFixture(FIXTURE), new SteppingClock(Duration.ofSeconds(10)));

        ObservabilityInspectionTask.DashboardInspection result = task.inspectDashboardSql();

        assertThat(result.executed()).containsExactly("Q2", "Q3", "Q5", "Q6");
        assertThat(result.hits()).isEmpty();
    }

    /**
     * 全部条目执行报错（如当月月表尚未建出）→ 记「未能判定」并降为 SKIP，不得读成「未命中即通过」。
     *
     * @throws IOException 夹具写盘失败时抛出
     * @return void；断言失败即空 executed + 空 hits 被当成绿灯（[148] 真机验证时暴露的假绿）
     */
    @Test
    @DisplayName("四条全报错（当月月表缺失）→ 状态 SKIP + 逐条记未能判定，不得记 PASS")
    void allQueriesFailedIsSkippedNotPassed() throws IOException {
        when(maintenanceMapper.executeDashboardQuery(anyString()))
                .thenThrow(new QueryTimeoutException("Table 's2s_track.track_event_202610' doesn't exist"));
        ObservabilityInspectionTask task = newTask(writeFixture(FIXTURE), fixedClock());

        ObservabilityInspectionTask.DashboardInspection result = task.inspectDashboardSql();

        assertThat(result.status()).isEqualTo("SKIP");
        assertThat(result.executed()).isEmpty();
        assertThat(result.hits()).isEmpty();
        assertThat(result.failed())
                .hasSize(4)
                .allSatisfy(item -> assertThat(item).contains("QueryTimeoutException"));
    }

    /**
     * 构造巡检任务（注入替身与时钟）。
     *
     * @param dashboardSqlPath 主看板 SQL 清单路径
     * @param clock            计时时钟
     * @return {@link ObservabilityInspectionTask} 被测任务
     */
    private ObservabilityInspectionTask newTask(String dashboardSqlPath, Clock clock) {
        return new ObservabilityInspectionTask(maintenanceMapper, restartWindowMapper,
                dashboardSqlPath, clock);
    }

    /**
     * 把夹具写入临时目录下的清单文件。
     *
     * @param content 文件全文
     * @return {@link String} 文件绝对路径
     * @throws IOException 写盘失败时抛出
     */
    private String writeFixture(String content) throws IOException {
        Path file = tempDir.resolve("dashboard_queries.sql");
        Files.writeString(file, content, StandardCharsets.UTF_8);
        return file.toString();
    }

    /**
     * 捕获全部下发给埋点库的 SQL（按调用顺序）。
     *
     * @return {@link List} SQL 文本
     */
    private List<String> capturedSql() {
        ArgumentCaptor<String> captor = ArgumentCaptor.forClass(String.class);
        verify(maintenanceMapper, atLeastOnce()).executeDashboardQuery(captor.capture());
        return captor.getAllValues();
    }

    /**
     * 构造一行重启窗口夹具。
     *
     * @param startAt 窗口起点
     * @param endAt   窗口终点
     * @return {@link RestartWindowEntity} 窗口实体
     */
    private static RestartWindowEntity window(LocalDateTime startAt, LocalDateTime endAt) {
        RestartWindowEntity entity = new RestartWindowEntity();
        entity.setStartAt(startAt);
        entity.setEndAt(endAt);
        return entity;
    }

    /**
     * 固定时钟（2026-10-10，Asia/Shanghai）：耗时恒为 0，用于非耗时断言。
     *
     * @return {@link Clock} 固定时钟
     */
    private static Clock fixedClock() {
        return Clock.fixed(Instant.parse("2026-10-10T00:00:00Z"), ZoneId.of("Asia/Shanghai"));
    }

    /**
     * 每次读 {@code instant()} 前进固定步长的测试时钟。
     *
     * <p>任务对每条 SQL 只取「开始/结束」两次时钟且其间无其他取时，故一次执行的耗时恰为一个步长，
     * 从而可确定性地验证「超阈值」「边界」两类判定，无需 sleep。</p>
     */
    private static final class SteppingClock extends Clock {

        /** 步长（每次读时的前进量）。 */
        private final Duration step;

        /** 基准时刻。 */
        private final Instant base = Instant.parse("2026-10-10T00:00:00Z");

        /** 已读取次数（每次 {@code instant()} 自增）。 */
        private final AtomicInteger ticks = new AtomicInteger();

        /**
         * 构造步进时钟。
         *
         * @param step 每次读时的前进量
         */
        SteppingClock(Duration step) {
            this.step = step;
        }

        /**
         * 取时区（Asia/Shanghai，与部署口径一致）。
         *
         * @return {@link ZoneId} 时区
         */
        @Override
        public ZoneId getZone() {
            return ZoneId.of("Asia/Shanghai");
        }

        /**
         * 返回同时区的本时钟（本测试不需要换区语义）。
         *
         * @param zone 目标时区
         * @return {@link Clock} 本实例
         */
        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        /**
         * 取当前时刻（每次调用前进一个步长）。
         *
         * @return {@link Instant} 当前时刻
         */
        @Override
        public Instant instant() {
            return base.plus(step.multipliedBy(ticks.getAndIncrement()));
        }
    }
}
