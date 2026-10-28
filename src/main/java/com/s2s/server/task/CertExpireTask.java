package com.s2s.server.task;

import com.s2s.server.common.constants.NfrTask;
import com.s2s.server.task.mapper.TaskMapper;
import java.time.LocalDateTime;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 资质到期流转任务（2026-10-28；资质取消人工审核后的唯一状态出口）。
 *
 * <p>把 {@code expire_at} 已过、且 {@code status='approved'} 的资质置为 {@code expired}：
 * {@code pending}/{@code rejected} 本轮不写入，故无需处理；「长期有效」
 * （{@code expire_type='permanent'}）不参与流转。</p>
 *
 * <p><b>为什么不在读路径上算</b>：档案页与详情页各自计算会让「凭证当前状态」出现两套
 * 实现，且每次请求都带时间判断；写进状态列后，读侧只按枚举渲染。</p>
 *
 * <p><b>到期不删任何东西</b>：记录、证照图、已挂载帖子的快照都保留——用户仍可编辑续期，
 * 详情页说明行由凭证当前状态派生（快照不回溯）。</p>
 *
 * <p>调度频率取「每日」；具体时刻取业务低峰 03:10。</p>
 */
@Component
public class CertExpireTask {

    private static final Logger log = LoggerFactory.getLogger(CertExpireTask.class);

    /**
     * 调度表达式：每日 03:10（六段 cron）。
     */
    private static final String CRON_DAILY = "0 10 3 * * *";

    private final TaskMapper taskMapper;

    /**
     * 构造资质到期任务。
     *
     * @param taskMapper 定时任务持久层（本任务只用 {@code expireCerts}）
     */
    public CertExpireTask(TaskMapper taskMapper) {
        this.taskMapper = taskMapper;
    }

    /**
     * 扫描并流转到期资质（分批推进直到收敛）。
     *
     * @return void；无到期资质时不产生任何日志（常态零输出，避免每日刷屏）
     */
    @Scheduled(cron = CRON_DAILY)
    public void expireCertificates() {
        LocalDateTime now = LocalDateTime.now();
        BatchCleanupRunner.BatchResult result = BatchCleanupRunner.run(
                limit -> taskMapper.expireCerts(now, limit));

        if (result.affectedRows() > 0) {
            log.info("资质到期流转：置 expired {} 行（converged={}）",
                    result.affectedRows(), result.converged());
        }
        if (!result.converged()) {
            log.warn("资质到期流转未在 {} 批内收敛，本批更新 {} 行——"
                            + "可能存在大批量积压或筛选条件异常，下次调度继续",
                    NfrTask.CLEANUP_MAX_BATCHES, result.affectedRows());
        }
    }
}
