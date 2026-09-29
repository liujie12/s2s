package com.s2s.server.track;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.track.dto.TrackEventItem;
import com.s2s.server.track.dto.TrackEventItem.EventName;
import com.s2s.server.track.dto.TrackEventsRequest;
import com.s2s.server.track.dto.TrackEventsResponse;
import com.s2s.server.track.mapper.TrackEventMapper;
import com.s2s.server.track.service.TrackService;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.slf4j.LoggerFactory;

/**
 * {@code layer_switch} 四段耗时一致性校验测试（[129]；详设 §5.8 第 [6] 步）。
 *
 * <p><b>为什么单列一个测试类</b>：该步的关键语义是「<b>不拒收</b>，仅记 WARN」——
 * 一个容易被「顺手改成抛异常」破坏的行为。用独立的「不抛异常 + 有/无 WARN」断言把它钉住。</p>
 */
class LayerSwitchConsistencyTest {

    private TrackPersistence trackPersistence;
    private TrackEventMapper mapper;
    private TrackService service;
    private Logger logger;
    private ListAppender<ILoggingEvent> appender;

    /**
     * 装配替身服务与日志采集器。
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
     * 卸载日志采集器。
     *
     * @return void
     */
    @AfterEach
    void tearDown() {
        logger.detachAppender(appender);
    }

    /**
     * 四段和（40）与 duration_ms（100）偏差 60ms &gt; 1ms → 不抛异常、照常落库、记 WARN。
     *
     * @return void；断言失败即「校验变为拒收」或观测缺失
     */
    @Test
    @DisplayName("四段和不符 → 不拒收，仅 WARN")
    void mismatchWarnsButDoesNotReject() {
        when(mapper.batchInsert(any(), anyList(), any(), any())).thenReturn(1);
        TrackEventItem event = new TrackEventItem(EventName.LAYER_SWITCH,
                Instant.parse("2026-09-29T10:00:00.000Z"), "ls-1", null,
                Map.of("duration_ms", 100, "t_cache_ms", 10, "t_net_ms", 10,
                        "t_agg_ms", 10, "t_render_ms", 10),
                null, null, null, null);

        TrackEventsResponse response = assertDoesNotReject(event);

        assertThat(response.accepted()).isEqualTo(1);
        assertThat(appender.list)
                .as("四段和不符须留 WARN（Batch1 不进数据质量看板，但须可观测）")
                .anyMatch(log -> log.getFormattedMessage().contains("layer_switch"));
    }

    /**
     * 四段和（40）与 duration_ms（40）自洽 → 不记 WARN。
     *
     * @return void；断言失败即判据过松（对合法事件误报）
     */
    @Test
    @DisplayName("四段和自洽 → 不记 WARN")
    void matchDoesNotWarn() {
        when(mapper.batchInsert(any(), anyList(), any(), any())).thenReturn(1);
        TrackEventItem event = new TrackEventItem(EventName.LAYER_SWITCH,
                Instant.parse("2026-09-29T10:00:00.000Z"), "ls-2", null,
                Map.of("duration_ms", 40, "t_cache_ms", 10, "t_net_ms", 10,
                        "t_agg_ms", 10, "t_render_ms", 10),
                null, null, null, null);

        assertDoesNotReject(event);

        assertThat(appender.list)
                .as("自洽事件不应产生 layer_switch 告警")
                .noneMatch(log -> log.getFormattedMessage().contains("layer_switch"));
    }

    /**
     * 四段耗时键缺失 → 跳过校验，不记 WARN、不抛异常。
     *
     * @return void；断言失败即缺键被误判为异常
     */
    @Test
    @DisplayName("四段耗时键缺失 → 跳过校验")
    void missingKeysSkipped() {
        when(mapper.batchInsert(any(), anyList(), any(), any())).thenReturn(1);
        TrackEventItem event = new TrackEventItem(EventName.LAYER_SWITCH,
                Instant.parse("2026-09-29T10:00:00.000Z"), "ls-3", null,
                Map.of("duration_ms", 100), null, null, null, null);

        assertDoesNotReject(event);

        assertThat(appender.list)
                .as("缺键不应触发 layer_switch 告警")
                .noneMatch(log -> log.getFormattedMessage().contains("layer_switch"));
    }

    /**
     * 执行一次上报（若抛异常则测试自然失败，即「校验不得演变为拒收」）。
     *
     * @param event 单个 layer_switch 事件
     * @return {@link TrackEventsResponse} 上报结果
     */
    private TrackEventsResponse assertDoesNotReject(TrackEventItem event) {
        return service.accept(1L, "dev", new TrackEventsRequest(List.of(event), 0));
    }
}
