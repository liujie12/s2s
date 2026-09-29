package com.s2s.server.common.observability;

import com.s2s.server.common.constants.NfrObs;
import com.s2s.server.common.observability.mapper.RestartWindowMapper;
import java.time.Clock;
import java.time.LocalDateTime;
import java.util.concurrent.atomic.AtomicBoolean;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.boot.context.event.ApplicationStartedEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/**
 * {@code restart_window} <b>唯一写入处</b>：服务端启动时自写一行
 * （详设 §21 缺口 #1「后半」；可观测性架构方案 §4.2.2）。
 *
 * <p><b>为什么这么设计</b>：可观测性 §4.2.2 的「重启窗口排除」规则要求把「发版重启窗口
 * 与重启后预热期」从 P95 分母剔除，否则 P95 会被预热期污染；该规则必须能被 SQL 判定，
 * 故需要一行 {@code start_at}/{@code end_at} 记录。客户端不知道服务端何时重启，因此由
 * 服务端启动时自写（详设 §21 缺口 #1 的处理建议）。本类是全系统唯一写该表处。</p>
 *
 * <p><b>时间口径</b>（可观测性 §4.2.2）：{@code start_at} 取
 * {@link ApplicationStartedEvent} 触发时刻（记为应用开始启动）；{@code end_at} =
 * {@link ApplicationReadyEvent} 触发时刻（启动完成）+
 * {@link NfrObs#RESTART_WARMUP_MINUTES} 分钟。</p>
 *
 * <p><b>写失败不阻断启动</b>（设计文档未明文，取最小安全默认）：插入失败时<b>记录 ERROR
 * 日志、不阻断应用启动</b>。理由：该行只用于 P95 分数剔除重启预热期，属可观测性记账；
 * 「必须阻断启动」的名单里没有它，为一行记账数据让服务起不来不划算。此语义与
 * {@code AuditLogWriter} 刻意相反——审计是合规举证唯一来源，写失败必须上抛；本处不上抛。</p>
 *
 * <p><b>幂等</b>：同一进程内只写一行。以 {@link AtomicBoolean} 守卫
 * {@link ApplicationReadyEvent} 的写入，重复触发（事件多播器异步化或事件重放）直接跳过，
 * 故同一进程不会写两行；跨进程（每次重启）各写一行，正是「行数 == 启动次数」的口径。</p>
 */
@Component
public class RestartWindowWriter {

    private static final Logger log = LoggerFactory.getLogger(RestartWindowWriter.class);

    /** 启动时间窗 Mapper（唯一 insert 出口）。 */
    private final RestartWindowMapper restartWindowMapper;

    /** 计时时钟（生产用系统时钟；测试注入可控时钟以确定断言 {@code end_at}）。 */
    private final Clock clock;

    /** 应用开始启动时刻，由 {@link ApplicationStartedEvent} 记录；volatile 防御异步事件多播器。 */
    private volatile LocalDateTime startAt;

    /** 是否已写入的守卫，保证同一进程只写一行。 */
    private final AtomicBoolean written = new AtomicBoolean(false);

    /**
     * 构造启动时间窗写入器（Spring 注入用的主构造器，使用系统默认时区时钟）。
     *
     * @param restartWindowMapper 启动时间窗 Mapper（由 Spring 注入）
     */
    @Autowired
    public RestartWindowWriter(RestartWindowMapper restartWindowMapper) {
        this(restartWindowMapper, Clock.systemDefaultZone());
    }

    /**
     * 构造启动时间窗写入器（可注入时钟，供测试确定断言时间语义）。
     *
     * @param restartWindowMapper 启动时间窗 Mapper
     * @param clock 计时时钟（生产为系统时钟；测试传可控时钟）
     */
    RestartWindowWriter(RestartWindowMapper restartWindowMapper, Clock clock) {
        this.restartWindowMapper = restartWindowMapper;
        this.clock = clock;
    }

    /**
     * 记录应用开始启动时刻（{@link ApplicationStartedEvent} 监听器）。
     *
     * @param event 应用已启动事件（本方法只借其触发时机，不使用事件载荷）
     * @return void（无返回值）
     */
    @EventListener
    public void onApplicationStarted(ApplicationStartedEvent event) {
        this.startAt = LocalDateTime.now(clock);
    }

    /**
     * 应用就绪时向 {@code restart_window} 写一行（{@link ApplicationReadyEvent} 监听器）。
     *
     * <p>{@code start_at} = 已记录的启动开始时刻（缺失时退化取当前时刻，保证列 NOT NULL）；
     * {@code end_at} = 当前时刻 + {@link NfrObs#RESTART_WARMUP_MINUTES} 分钟。同一进程只写一次
     * （{@link AtomicBoolean} 守卫）；写失败记录 ERROR 日志、不抛异常、不阻断启动。</p>
     *
     * @param event 应用就绪事件（本方法只借其触发时机，不使用事件载荷）
     * @return void（无返回值）
     */
    @EventListener
    public void onApplicationReady(ApplicationReadyEvent event) {
        if (!written.compareAndSet(false, true)) {
            log.debug("RESTART_WINDOW_WRITE_SKIP: 本进程已写入 restart_window，跳过重复触发");
            return;
        }

        LocalDateTime completedAt = LocalDateTime.now(clock);
        LocalDateTime windowStart = startAt != null ? startAt : completedAt;

        RestartWindowEntity entity = new RestartWindowEntity();
        entity.setStartAt(windowStart);
        entity.setEndAt(completedAt.plusMinutes(NfrObs.RESTART_WARMUP_MINUTES));
        try {
            restartWindowMapper.insert(entity);
            log.info("RESTART_WINDOW_WRITE: startAt={}, endAt={}", windowStart, entity.getEndAt());
        } catch (RuntimeException exception) {
            // 设计文档未明文，取最小安全默认：记录 ERROR 日志、不阻断应用启动。
            // 该行只影响 P95 分母剔除，不影响业务可用性，不能因此让服务起不来。
            log.error("RESTART_WINDOW_WRITE_FAILED: 启动时间窗写入失败，已忽略以不阻断应用启动", exception);
        }
    }
}
