package com.s2s.server.task;

import com.s2s.server.common.constants.NfrPostView;
import com.s2s.server.common.constants.NfrTask;
import com.s2s.server.task.mapper.TaskMapper;
import java.time.Clock;
import java.time.LocalDate;
import java.time.ZoneId;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 浏览明细清理任务（保留策略 {@code post_view_detail_30d}）。
 *
 * <p>物理删除 {@code view_day} 早于保留期的 {@code post_view} 明细；日计数表
 * {@code post_view_daily} 永久保留，因此清理不会让帖主浏览数变小。</p>
 *
 * <p>批次参数见 {@link NfrTask}；调度取业务低峰每日一次。</p>
 */
@Component
public class PostViewCleanupTask {

    private static final Logger log = LoggerFactory.getLogger(PostViewCleanupTask.class);

    /** 调度表达式：每日 04:50（六段 cron；与收藏清理错开 10 分钟）。 */
    private static final String CRON_DAILY = "0 50 4 * * *";

    /** 业务日时区：与浏览上报口径一致。 */
    private static final ZoneId ZONE = ZoneId.of("Asia/Shanghai");

    private final TaskMapper taskMapper;
    private final Clock clock;

    /**
     * 构造浏览明细清理任务。
     *
     * <p><b>必须显式 {@code @Autowired}</b>：本类有两个构造器（生产 + 测试注入
     * {@code Clock}），Spring 无法自行选定，缺注解时启动报
     * 「No default constructor found」（2026-10-27 真机冒烟首启实测；
     * 同类既有范式见 {@code ObservabilityInspectionTask}）。</p>
     *
     * @param taskMapper 定时任务持久层（本任务只用 {@code deletePostViewsBefore}）
     */
    @Autowired
    public PostViewCleanupTask(TaskMapper taskMapper) {
        this(taskMapper, Clock.system(ZONE));
    }

    /**
     * 构造浏览明细清理任务（测试可注入固定时钟）。
     *
     * @param taskMapper 定时任务持久层
     * @param clock      业务日时钟
     */
    PostViewCleanupTask(TaskMapper taskMapper, Clock clock) {
        this.taskMapper = taskMapper;
        this.clock = clock;
    }

    /**
     * 分批删除超期浏览明细直到收敛。
     *
     * @return void；无超期行时不产生日志
     */
    @Scheduled(cron = CRON_DAILY)
    public void deleteExpiredViews() {
        LocalDate threshold = LocalDate.now(clock).minusDays(NfrPostView.DETAIL_RETENTION_DAYS);
        BatchCleanupRunner.BatchResult result = BatchCleanupRunner.run(
                limit -> taskMapper.deletePostViewsBefore(threshold, limit));

        if (result.affectedRows() > 0) {
            log.info("浏览明细清理：删除 {} 行（保留 {} 天，日计数不动）",
                    result.affectedRows(), NfrPostView.DETAIL_RETENTION_DAYS);
        }
        if (!result.converged()) {
            log.warn("浏览明细清理未在 {} 批内收敛，本批删除 {} 行——下次调度继续",
                    NfrTask.CLEANUP_MAX_BATCHES, result.affectedRows());
        }
    }
}
