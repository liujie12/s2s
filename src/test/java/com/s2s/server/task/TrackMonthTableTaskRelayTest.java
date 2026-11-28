package com.s2s.server.task;

import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.track.TrackPersistence;
import com.s2s.server.track.dto.TrackFallbackRow;
import com.s2s.server.track.mapper.TrackFallbackMapper;
import com.s2s.server.track.mapper.TrackMaintenanceMapper;
import java.sql.SQLException;
import java.time.LocalDateTime;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.UncategorizedSQLException;

/**
 * {@link TrackMonthTableTask#relayFallbackRows()} 测试（数据库设计 §3.17）。
 *
 * <p>覆盖：按 {@code ts} 分月搬运、搬完即删、月表缺失（1146）时保留不删、空表零调用。
 * 纯单元测试：埋点库入口与两个 Mapper 均为 Mockito 替身，不连库。</p>
 */
class TrackMonthTableTaskRelayTest {

    /** 2026-11 采集时刻夹具（UTC，与落库口径一致）。 */
    private static final LocalDateTime NOV_TS = LocalDateTime.of(2026, 11, 13, 15, 0, 0, 123_000_000);

    /** 2026-09 采集时刻夹具。 */
    private static final LocalDateTime SEP_TS = LocalDateTime.of(2026, 9, 30, 12, 0, 0, 123_000_000);

    private TrackFallbackMapper fallbackMapper;
    private TrackMonthTableTask task;

    /**
     * 装配任务：mock 埋点库入口并交出维护/搬运两个 Mapper。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        TrackPersistence persistence = mock(TrackPersistence.class);
        when(persistence.mapper(TrackMaintenanceMapper.class)).thenReturn(mock(TrackMaintenanceMapper.class));
        fallbackMapper = mock(TrackFallbackMapper.class);
        when(persistence.mapper(TrackFallbackMapper.class)).thenReturn(fallbackMapper);
        task = new TrackMonthTableTask(persistence);
    }

    /**
     * 同一批跨月行按目标月表分组搬运，成功后删除对应行。
     *
     * @return void；断言失败即搬错月表或漏删兜底行
     */
    @Test
    @DisplayName("按 ts 分月搬运：两月各搬各删")
    void relaysRowsGroupedByMonthThenDeletes() {
        when(fallbackMapper.selectPending(anyInt())).thenReturn(List.of(
                row(1L, NOV_TS), row(2L, NOV_TS), row(3L, SEP_TS)));
        when(fallbackMapper.relayToMonth(anyString(), anyList())).thenReturn(1);

        task.relayFallbackRows();

        verify(fallbackMapper).relayToMonth(eq("track_event_202611"), eq(List.of(1L, 2L)));
        verify(fallbackMapper).relayToMonth(eq("track_event_202609"), eq(List.of(3L)));
        verify(fallbackMapper).deleteByIds(List.of(1L, 2L));
        verify(fallbackMapper).deleteByIds(List.of(3L));
    }

    /**
     * 月表缺失（1146）时该组行必须保留：不删除、不抛异常，等待下次重搬。
     *
     * @return void；断言失败即缺表时丢行
     */
    @Test
    @DisplayName("月表缺失 1146：保留兜底行不删除")
    void keepsRowsWhenMonthTableMissing() {
        when(fallbackMapper.selectPending(anyInt())).thenReturn(List.of(row(11L, NOV_TS)));
        when(fallbackMapper.relayToMonth(anyString(), anyList())).thenThrow(
                new UncategorizedSQLException("relay", "INSERT ...",
                        new SQLException("Table doesn't exist", "42S02", 1146)));

        task.relayFallbackRows();

        verify(fallbackMapper, never()).deleteByIds(anyList());
    }

    /**
     * 兜底表为空时不得发起任何搬运/删除调用。
     *
     * @return void；断言失败即空表仍产生无谓写请求
     */
    @Test
    @DisplayName("兜底表为空：零搬运零删除")
    void doesNothingWhenNoPendingRows() {
        when(fallbackMapper.selectPending(anyInt())).thenReturn(List.of());

        task.relayFallbackRows();

        verify(fallbackMapper, never()).relayToMonth(anyString(), anyList());
        verify(fallbackMapper, never()).deleteByIds(anyList());
    }

    /**
     * 构造兜底行夹具。
     *
     * @param id 行 ID
     * @param ts 采集时刻（UTC）
     * @return {@link TrackFallbackRow} 夹具行
     */
    private static TrackFallbackRow row(Long id, LocalDateTime ts) {
        TrackFallbackRow row = new TrackFallbackRow();
        row.setId(id);
        row.setTs(ts);
        return row;
    }
}
