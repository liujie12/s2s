package com.s2s.server.task;

import com.s2s.server.common.constants.NfrTask;
import com.s2s.server.task.mapper.TaskMapper;
import java.time.LocalDateTime;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 到期帖自动下架任务（[129] P4；架构 §8 任务 1；详设 §6 任务 #1）。
 *
 * <p>把 {@code expire_at} 已过、且仍在架（{@code status='active'}）的帖子转为
 * {@code archived + status_reason=1}（对外派生为 {@code expired}，见 {@code PostStatus}）。</p>
 *
 * <p><b>两个关键口径</b>：</p>
 * <ol>
 *   <li><b>不守 version</b>：详设 §5.3.3 的写守卫分流把「系统派生变更」单列为
 *       {@code WHERE id=? AND status IN (合法前驱集)}——定时任务不持有用户视图的 version，
 *       若也守则会被用户的并发编辑饿死。本任务天然是集合更新（无单条 id），
 *       守 {@code status='active'} 即等价于「合法前驱集」。</li>
 *   <li><b>时间口径与写入侧一致</b>：{@code PostService} 用 {@code LocalDateTime.now()}
 *       写 {@code expire_at}（JVM 默认时区），本任务必须用同一口径取「当前时刻」——
 *       若此处改用 UTC，会与库内时间基准错位整个时区差，导致帖子提前或延后数小时下架。</li>
 * </ol>
 *
 * <p>批次参数见 {@link com.s2s.server.common.constants.NfrTask}；调度频率取详设 §6 任务列
 * 「每 10 分钟」。</p>
 */
@Component
public class PostExpireTask {

    private static final Logger log = LoggerFactory.getLogger(PostExpireTask.class);

    /**
     * 调度表达式：每 10 分钟整点触发（六段 cron，详设 §6 任务 #1 频率列）。
     */
    private static final String CRON_EVERY_TEN_MINUTES = "0 */10 * * * *";

    private final TaskMapper taskMapper;

    /**
     * 构造到期下架任务。
     *
     * @param taskMapper 定时任务持久层（本任务只用 {@code archiveExpiredPosts}）
     */
    public PostExpireTask(TaskMapper taskMapper) {
        this.taskMapper = taskMapper;
    }

    /**
     * 扫描并归档到期帖子（分批推进直到收敛）。
     *
     * @return void；无到期帖时不产生任何日志（常态零输出，避免每 10 分钟刷屏）
     */
    @Scheduled(cron = CRON_EVERY_TEN_MINUTES)
    public void archiveExpiredPosts() {
        LocalDateTime now = LocalDateTime.now();
        BatchCleanupRunner.BatchResult result = BatchCleanupRunner.run(
                limit -> taskMapper.archiveExpiredPosts(now, limit));

        if (result.affectedRows() > 0) {
            log.info("到期帖自动下架：归档 {} 行（converged={}）",
                    result.affectedRows(), result.converged());
        }
        if (!result.converged()) {
            log.warn("到期帖自动下架未在 {} 批内收敛，本批归档 {} 行——"
                            + "可能存在大批量积压或筛选条件异常，下次调度继续",
                    NfrTask.CLEANUP_MAX_BATCHES, result.affectedRows());
        }
    }
}
