package com.s2s.server.task;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.track.TrackPersistence;
import com.s2s.server.track.mapper.TrackFallbackMapper;
import com.s2s.server.track.mapper.TrackMaintenanceMapper;
import java.time.YearMonth;
import java.time.ZoneOffset;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * {@link TrackMonthTableTask} 月表兜底确保测试（DEF-04）。
 *
 * <p>覆盖：当前月缺失时自愈、下月缺失时补建、结构模板取库内最新月表、
 * 库内无任何合法月表时不动手、启动兜底失败不阻塞启动。</p>
 */
class TrackMonthTableTaskEnsureTest {

    /** 当前月按 UTC 计算（与事件 ts 归属口径一致）。 */
    private static final YearMonth CURRENT = YearMonth.now(ZoneOffset.UTC);

    private TrackMaintenanceMapper maintenanceMapper;
    private TrackMonthTableTask task;

    /**
     * 装配任务：维护 Mapper 为 mock，搬运 Mapper 仅为构造需要。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        TrackPersistence persistence = mock(TrackPersistence.class);
        maintenanceMapper = mock(TrackMaintenanceMapper.class);
        when(persistence.mapper(TrackMaintenanceMapper.class)).thenReturn(maintenanceMapper);
        when(persistence.mapper(TrackFallbackMapper.class)).thenReturn(mock(TrackFallbackMapper.class));
        task = new TrackMonthTableTask(persistence);
    }

    /**
     * 当前月已存在、下月缺失：只补下月，模板取当前月。
     *
     * @return void；断言失败即重复建表或模板取错
     */
    @Test
    @DisplayName("下月缺失：只建下月，模板=当前月")
    void createsNextMonthOnly() {
        String current = TrackTableNames.of(CURRENT);
        when(maintenanceMapper.listMonthTables()).thenReturn(List.of("track_event_202609", current));

        task.ensureMonthTablesOnStartup();

        verify(maintenanceMapper, never()).createTableLike(eq(current), anyString());
        verify(maintenanceMapper).createTableLike(TrackTableNames.of(CURRENT.plusMonths(1)), current);
    }

    /**
     * 当前月缺失（如新库跨月）：当前月与下月都补，模板取库内最新既有月表。
     *
     * @return void；断言失败即新部署跨月仍缺表
     */
    @Test
    @DisplayName("当前月缺失：当月+下月都补，模板=最新既有表")
    void createsCurrentAndNextFromLatestTemplate() {
        when(maintenanceMapper.listMonthTables()).thenReturn(List.of("track_event_202609"));

        task.ensureMonthTablesDaily();

        verify(maintenanceMapper).createTableLike(TrackTableNames.of(CURRENT), "track_event_202609");
        verify(maintenanceMapper).createTableLike(
                TrackTableNames.of(CURRENT.plusMonths(1)), "track_event_202609");
    }

    /**
     * 库内没有任何合法月表：不猜测结构，不建表。
     *
     * @return void；断言失败即用非月表或空模板建出错误结构
     */
    @Test
    @DisplayName("无任何合法月表：不建表")
    void skipsWhenNoTemplate() {
        when(maintenanceMapper.listMonthTables()).thenReturn(List.of());

        task.ensureMonthTablesOnStartup();

        verify(maintenanceMapper, never()).createTableLike(anyString(), anyString());
    }

    /**
     * 启动兜底失败不得让启动失败：读取表清单抛异常时方法仍需正常返回。
     *
     * @return void；断言失败即建表故障阻塞应用启动
     */
    @Test
    @DisplayName("启动兜底异常：不阻塞启动")
    void startupFailureDoesNotThrow() {
        when(maintenanceMapper.listMonthTables()).thenThrow(new RuntimeException("db down"));

        assertThatCode(task::ensureMonthTablesOnStartup).doesNotThrowAnyException();
    }
}
