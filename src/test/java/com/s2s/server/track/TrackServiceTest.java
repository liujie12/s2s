package com.s2s.server.track;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.constants.NfrApi;
import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.track.dto.TrackEventItem;
import com.s2s.server.track.dto.TrackEventItem.EventName;
import com.s2s.server.track.dto.TrackEventsRequest;
import com.s2s.server.track.dto.TrackEventsResponse;
import com.s2s.server.track.mapper.TrackEventMapper;
import com.s2s.server.track.service.TrackService;
import java.sql.SQLException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.UncategorizedSQLException;

/**
 * {@link TrackService} 七步链路测试（[129]；详设 §5.8）。
 *
 * <p>覆盖：批次上限 → {@code 42906}；按客户端 {@code ts} 归月表（含跨月与月初边界）；
 * 月表报 1146 降级写兜底表；{@code accepted} 取受影响行数之和；{@code dropped_count}
 * 仅在 &gt;0 时打 WARN。</p>
 *
 * <p>纯单元测试：{@code TrackPersistence} 与 Mapper 均以 Mockito 替身注入，不连库。</p>
 */
class TrackServiceTest {

    /** 用户 ID 夹具。 */
    private static final Long USER_ID = 1001L;

    /** 设备 ID 夹具。 */
    private static final String DEVICE_ID = "device-abc";

    private TrackPersistence trackPersistence;
    private TrackEventMapper mapper;
    private TrackService service;
    private Logger logger;
    private ListAppender<ILoggingEvent> appender;

    /**
     * 装配替身服务：mock 埋点库入口与 Mapper，并挂 Logback 采集器以断言 WARN 行为。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        trackPersistence = mock(TrackPersistence.class);
        mapper = mock(TrackEventMapper.class);
        when(trackPersistence.mapper(TrackEventMapper.class)).thenReturn(mapper);
        service = new TrackService(trackPersistence, new ObjectMapper());

        logger = (Logger) LoggerFactory.getLogger(TrackService.class);
        appender = new ListAppender<>();
        appender.start();
        logger.addAppender(appender);
    }

    /**
     * 卸载日志采集器，避免跨用例串扰。
     *
     * @return void
     */
    @AfterEach
    void tearDown() {
        logger.detachAppender(appender);
    }

    /**
     * 事件数超过批次上限（{@code NfrApi.TRACK_BATCH_MAX_EVENTS}）→ {@code 42906}，
     * 且不触达 Mapper（批次校验先于任何落库）。
     *
     * @return void；断言失败即批次上限未生效
     */
    @Test
    @DisplayName("事件数超批次上限 → 42906（且不触达落库）")
    void batchOverLimitRejectedWithTrackLimit() {
        List<TrackEventItem> events = new ArrayList<>();
        for (int i = 0; i < NfrApi.TRACK_BATCH_MAX_EVENTS + 1; i++) {
            events.add(item(EventName.POST_PUBLISHED, "i-" + i, Instant.parse("2026-09-29T10:00:00.000Z")));
        }

        assertThatThrownBy(() -> service.accept(USER_ID, DEVICE_ID, new TrackEventsRequest(events, 0)))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> {
                    BizException biz = (BizException) ex;
                    assertThat(biz.getErrorCode()).isSameAs(ErrorCode.TRACK_LIMIT);
                    assertThat(biz.getRetryAfterSeconds())
                            .isEqualTo(RateLimitThresholds.WINDOW_MINUTE_SECONDS);
                });
        verifyNoInteractions(mapper);
    }

    /**
     * 恰好等于批次上限不拒收（边界含等号）。
     *
     * @return void；断言失败即边界判定写成 &gt;= 的 off-by-one
     */
    @Test
    @DisplayName("事件数恰好等于上限 → 正常处理")
    void batchAtLimitAccepted() {
        List<TrackEventItem> events = new ArrayList<>();
        for (int i = 0; i < NfrApi.TRACK_BATCH_MAX_EVENTS; i++) {
            events.add(item(EventName.POST_PUBLISHED, "i-" + i, Instant.parse("2026-09-29T10:00:00.000Z")));
        }
        when(mapper.batchInsert(any(), anyList(), any(), any())).thenReturn(NfrApi.TRACK_BATCH_MAX_EVENTS);

        TrackEventsResponse response =
                service.accept(USER_ID, DEVICE_ID, new TrackEventsRequest(events, 0));

        assertThat(response.accepted()).isEqualTo(NfrApi.TRACK_BATCH_MAX_EVENTS);
    }

    /**
     * 月初/月末边界：{@code 2026-09-30T23:59:59.999Z} 归 202609、
     * {@code 2026-10-01T00:00:00.000Z} 归 202610；两表分别落库。
     *
     * @return void；断言失败即按到达时刻或错误时区归月
     */
    @Test
    @DisplayName("按客户端 ts 归月表（跨月边界两侧各归各月）")
    void routesToMonthTableByClientTs() {
        when(mapper.batchInsert(any(), anyList(), any(), any())).thenReturn(1);
        List<TrackEventItem> events = List.of(
                item(EventName.POST_PUBLISHED, "sep", Instant.parse("2026-09-30T23:59:59.999Z")),
                item(EventName.POST_PUBLISHED, "oct", Instant.parse("2026-10-01T00:00:00.000Z")));

        service.accept(USER_ID, DEVICE_ID, new TrackEventsRequest(events, 0));

        verify(mapper).batchInsert(eq("track_event_202609"), anyList(), eq(USER_ID), eq(DEVICE_ID));
        verify(mapper).batchInsert(eq("track_event_202610"), anyList(), eq(USER_ID), eq(DEVICE_ID));
    }

    /**
     * 归月纯函数边界：月初零点归当月，跨年边界正确。
     *
     * @return void；断言失败即月格式或时区换算错误
     */
    @Test
    @DisplayName("归月纯函数：月初零点与跨年边界")
    void monthTableOfBoundaries() {
        assertThat(TrackService.monthTableOf(Instant.parse("2026-09-01T00:00:00.000Z")))
                .isEqualTo("track_event_202609");
        assertThat(TrackService.monthTableOf(Instant.parse("2026-12-31T23:59:59.999Z")))
                .isEqualTo("track_event_202612");
        assertThat(TrackService.monthTableOf(Instant.parse("2027-01-01T00:00:00.000Z")))
                .isEqualTo("track_event_202701");
    }

    /**
     * 写月表报 MySQL 1146（表不存在）→ 降级写 {@code track_event_fallback}，
     * 且 {@code accepted} 取兜底表写入的受影响行数。
     *
     * @return void；断言失败即跨月零点数据会在静默中丢失
     */
    @Test
    @DisplayName("月表 1146 → 降级写兜底表")
    void fallsBackWhenMonthTableMissing() {
        DataAccessException missingTable = new UncategorizedSQLException(
                "trackEventMapper.batchInsert",
                "INSERT INTO track_event_202609 ...",
                new SQLException("Table 's2s_track.track_event_202609' doesn't exist", "42S02", 1146));
        when(mapper.batchInsert(eq("track_event_202609"), anyList(), any(), any()))
                .thenThrow(missingTable);
        when(mapper.batchInsert(eq("track_event_fallback"), anyList(), any(), any())).thenReturn(1);

        TrackEventsResponse response = service.accept(USER_ID, DEVICE_ID,
                new TrackEventsRequest(
                        List.of(item(EventName.POST_PUBLISHED, "sep", Instant.parse("2026-09-29T10:00:00.000Z"))),
                        0));

        assertThat(response.accepted()).isEqualTo(1);
        verify(mapper).batchInsert(eq("track_event_fallback"), anyList(), eq(USER_ID), eq(DEVICE_ID));
    }

    /**
     * 非 1146 的数据访问异常不吞、原样上抛（不把真实故障伪装成兜底成功）。
     *
     * @return void；断言失败即故障被静默降级
     */
    @Test
    @DisplayName("月表非 1146 异常 → 原样上抛，不降级")
    void nonMissingTableErrorPropagates() {
        DataAccessException other = new UncategorizedSQLException(
                "trackEventMapper.batchInsert", "INSERT ...",
                new SQLException("Lock wait timeout exceeded", "HY000", 1205));
        when(mapper.batchInsert(any(), anyList(), any(), any())).thenThrow(other);

        assertThatThrownBy(() -> service.accept(USER_ID, DEVICE_ID,
                new TrackEventsRequest(
                        List.of(item(EventName.POST_PUBLISHED, "x", Instant.parse("2026-09-29T10:00:00.000Z"))),
                        0)))
                .isSameAs(other);
    }

    /**
     * {@code accepted} = 各分组受影响行数之和（重复行返回 0、新行返回 1）。
     *
     * @return void；断言失败即 accepted 口径变成「接收条数」
     */
    @Test
    @DisplayName("accepted 取受影响行数之和（非接收条数）")
    void acceptedIsSumOfAffectedRows() {
        when(mapper.batchInsert(eq("track_event_202609"), anyList(), any(), any())).thenReturn(2);
        when(mapper.batchInsert(eq("track_event_202610"), anyList(), any(), any())).thenReturn(3);
        List<TrackEventItem> events = List.of(
                item(EventName.POST_PUBLISHED, "sep-1", Instant.parse("2026-09-10T10:00:00.000Z")),
                item(EventName.POST_PUBLISHED, "sep-2", Instant.parse("2026-09-11T10:00:00.000Z")),
                item(EventName.POST_PUBLISHED, "oct-1", Instant.parse("2026-10-02T10:00:00.000Z")));

        TrackEventsResponse response = service.accept(USER_ID, DEVICE_ID,
                new TrackEventsRequest(events, 0));

        assertThat(response.accepted()).isEqualTo(5);
    }

    /**
     * 落库行的 {@code user_id} 取自入参（登录态）、{@code device_id} 取自请求头，
     * 不来自请求体。
     *
     * @return void；断言失败即用户/设备标识来源被污染
     */
    @Test
    @DisplayName("user_id 取登录态、device_id 取请求头")
    void userIdAndDeviceIdFromTrustedSources() {
        when(mapper.batchInsert(any(), anyList(), any(), any())).thenReturn(1);

        service.accept(7L, "dev-7", new TrackEventsRequest(
                List.of(item(EventName.CONTACT_EVENT, "c", Instant.parse("2026-09-29T10:00:00.000Z"))), 0));

        verify(mapper).batchInsert(eq("track_event_202609"), anyList(), eq(7L), eq("dev-7"));
    }

    /**
     * {@code dropped_count > 0} 时打一条含 {@code droppedCount} 的结构化 WARN。
     *
     * @return void；断言失败即客户端丢弃缺口（#5）无观测
     */
    @Test
    @DisplayName("dropped_count > 0 → 记 WARN 日志")
    void droppedCountPositiveLogged() {
        when(mapper.batchInsert(any(), anyList(), any(), any())).thenReturn(1);

        service.accept(USER_ID, DEVICE_ID, new TrackEventsRequest(
                List.of(item(EventName.POST_PUBLISHED, "x", Instant.parse("2026-09-29T10:00:00.000Z"))), 2));

        assertThat(appender.list)
                .as("dropped_count>0 须留下观测（含 userId 与本批大小）")
                .anyMatch(event -> event.getFormattedMessage().contains("droppedCount=2")
                        && event.getFormattedMessage().contains(String.valueOf(USER_ID)));
    }

    /**
     * {@code dropped_count == 0} 时不打该日志（避免常态噪声）。
     *
     * @return void；断言失败即日志刷屏
     */
    @Test
    @DisplayName("dropped_count == 0 → 不打丢弃日志")
    void droppedCountZeroNotLogged() {
        when(mapper.batchInsert(any(), anyList(), any(), any())).thenReturn(1);

        service.accept(USER_ID, DEVICE_ID, new TrackEventsRequest(
                List.of(item(EventName.POST_PUBLISHED, "x", Instant.parse("2026-09-29T10:00:00.000Z"))), 0));

        assertThat(appender.list)
                .as("dropped_count=0 不应产生丢弃告警")
                .noneMatch(event -> event.getFormattedMessage().contains("droppedCount"));
    }

    /**
     * 构造一条事件夹具。
     *
     * @param name          事件名
     * @param interactionId 交互标识
     * @param ts            采集时刻
     * @return {@link TrackEventItem} 仅填必填字段的事件项
     */
    private static TrackEventItem item(EventName name, String interactionId, Instant ts) {
        return new TrackEventItem(name, ts, interactionId, null, null, null, null, null, null);
    }
}
