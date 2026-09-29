package com.s2s.server.common.observability;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.constants.NfrObs;
import com.s2s.server.common.observability.mapper.RestartWindowMapper;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneId;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.boot.context.event.ApplicationStartedEvent;

/**
 * {@link RestartWindowWriter} 行为测试（条目 [129] P1；可观测性架构方案 §4.2.2；详设 §21 #1）。
 *
 * <p>覆盖测试场景：
 * <ol>
 *   <li>字段语义：{@code start_at} = 启动开始时刻、{@code end_at} = 启动完成时刻 +
 *       {@link NfrObs#RESTART_WARMUP_MINUTES} 分钟，且 {@code start_at} 不晚于 {@code end_at}；</li>
 *   <li>写失败不阻断启动：Mapper 抛异常时组件不抛（设计文档未明文，取最小安全默认）；</li>
 *   <li>同一进程只写一行：就绪事件触发两次只 insert 一次（{@code AtomicBoolean} 守卫幂等）。</li>
 * </ol>
 *
 * <p>时间断言用可推进的 {@link AdjustableClock} 固定，断言以
 * {@link NfrObs#RESTART_WARMUP_MINUTES} 换算，不在测试里重写字面量 5（仓库硬纪律
 * 「不复制字面量」）。</p>
 */
class RestartWindowWriterTest {

    /** 断言用固定时区（与常量 {@code RateLimitThresholds.ZONE} 无关，仅测试内定位时间）。 */
    private static final ZoneId ZONE = ZoneId.of("Asia/Shanghai");

    /** 应用开始启动时刻（测试基准）。 */
    private static final Instant START_INSTANT = Instant.parse("2026-09-28T00:00:00Z");

    /** 启动开始 → 启动完成之间的耗时（用于让 {@code start_at} 严格早于 {@code end_at}）。 */
    private static final Duration START_TO_READY = Duration.ofSeconds(30);

    /** 可推进时钟。 */
    private AdjustableClock clock;

    /** mock 的启动时间窗 Mapper。 */
    private RestartWindowMapper restartWindowMapper;

    /** 被测写入器。 */
    private RestartWindowWriter writer;

    /**
     * 每测前置：构造可推进时钟、mock Mapper 与被测写入器。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        clock = new AdjustableClock(START_INSTANT, ZONE);
        restartWindowMapper = mock(RestartWindowMapper.class);
        writer = new RestartWindowWriter(restartWindowMapper, clock);
    }

    /**
     * 场景一：写入行的字段语义——{@code start_at} 取启动开始时刻，{@code end_at} 取
     * 启动完成时刻 + 预热窗口常量，且 {@code start_at} 不晚于 {@code end_at}。
     *
     * @return void（断言失败即抛）
     */
    @Test
    @DisplayName("写一行：start_at=启动开始时刻，end_at=启动完成时刻+预热窗口常量")
    void writesOneRowWithWarmupWindowSemantics() {
        writer.onApplicationStarted(mock(ApplicationStartedEvent.class));
        clock.advance(START_TO_READY);
        writer.onApplicationReady(mock(ApplicationReadyEvent.class));

        ArgumentCaptor<RestartWindowEntity> captor = ArgumentCaptor.forClass(RestartWindowEntity.class);
        verify(restartWindowMapper, times(1)).insert(captor.capture());
        RestartWindowEntity saved = captor.getValue();

        LocalDateTime expectedStart = LocalDateTime.ofInstant(START_INSTANT, ZONE);
        LocalDateTime expectedReadyAt = LocalDateTime.ofInstant(START_INSTANT.plus(START_TO_READY), ZONE);

        assertThat(saved.getStartAt()).isEqualTo(expectedStart);
        assertThat(saved.getStartAt()).isBeforeOrEqualTo(saved.getEndAt());
        assertThat(saved.getEndAt()).isEqualTo(expectedReadyAt.plusMinutes(NfrObs.RESTART_WARMUP_MINUTES));
    }

    /**
     * 场景二：插入失败不阻断启动——Mapper 抛 {@link RuntimeException} 时组件吞掉并记 ERROR 日志，
     * 不向上抛出（设计文档未明文，取最小安全默认）。
     *
     * @return void（若组件抛异常则断言失败）
     */
    @Test
    @DisplayName("写失败不抛：Mapper 抛异常时组件不阻断应用启动")
    void insertFailureDoesNotThrow() {
        when(restartWindowMapper.insert(any(RestartWindowEntity.class)))
                .thenThrow(new RuntimeException("db down"));

        assertThatCode(() -> {
            writer.onApplicationStarted(mock(ApplicationStartedEvent.class));
            writer.onApplicationReady(mock(ApplicationReadyEvent.class));
        }).doesNotThrowAnyException();

        verify(restartWindowMapper, times(1)).insert(any(RestartWindowEntity.class));
    }

    /**
     * 场景三：同一进程只写一行——就绪事件重复触发只 insert 一次。
     *
     * @return void（若写了两行则断言失败）
     */
    @Test
    @DisplayName("幂等：就绪事件触发两次只写一行")
    void readyEventFiredTwiceWritesOnlyOnce() {
        writer.onApplicationStarted(mock(ApplicationStartedEvent.class));
        writer.onApplicationReady(mock(ApplicationReadyEvent.class));
        writer.onApplicationReady(mock(ApplicationReadyEvent.class));

        verify(restartWindowMapper, times(1)).insert(any(RestartWindowEntity.class));
    }

    /**
     * 可推进时钟：{@code instant()} 返回可被 {@link #advance(Duration)} 推前的固定时刻，
     * 使「启动开始 → 启动完成」的耗时在测试内可控，从而对 {@code end_at} 做确定性断言。
     */
    private static final class AdjustableClock extends Clock {

        /** 当前时刻。 */
        private Instant instant;

        /** 时区。 */
        private final ZoneId zone;

        /**
         * 构造可推进时钟。
         *
         * @param instant 初始时刻
         * @param zone 时区
         */
        AdjustableClock(Instant instant, ZoneId zone) {
            this.instant = instant;
            this.zone = zone;
        }

        /**
         * 推前当前时刻。
         *
         * @param duration 推前时长
         * @return void
         */
        void advance(Duration duration) {
            this.instant = this.instant.plus(duration);
        }

        @Override
        public ZoneId getZone() {
            return zone;
        }

        @Override
        public Clock withZone(ZoneId newZone) {
            return new AdjustableClock(instant, newZone);
        }

        @Override
        public Instant instant() {
            return instant;
        }
    }
}
