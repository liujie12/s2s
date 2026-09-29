package com.s2s.server.task;

import com.s2s.server.common.constants.NfrTask;
import java.util.function.IntFunction;

/**
 * 分批收敛执行器（[129] P4；抽提依据：编码规范 §1.1「共享逻辑第二次出现即上浮」——
 * 到期下架、审计清理、收藏物删、媒体孤儿清理四处都需要「小批推进直到不足一批」）。
 *
 * <p><b>为什么要分批而不是一次删完</b>：一次性更新/删除大量行会长时间持锁并膨胀 undo
 * （数据库设计 §6.5 对埋点表的同类告诫），在 2 核 2G 实例上会拖累整个库；
 * 分批让每次事务短小、可被调度线程安全中断。</p>
 *
 * <p><b>为什么要有迭代上限</b>：若过滤条件写错导致命中面远大于预期，无上限的循环会让
 * 单次调度无界耗时。达到上限时返回 {@code converged=false}，由调用方记 WARN——
 * 「没跑完」必须可见，不能静默当作跑完。</p>
 */
final class BatchCleanupRunner {

    /**
     * 私有构造器：纯静态工具，无实例状态。
     */
    private BatchCleanupRunner() {
    }

    /**
     * 反复调用一步批处理，直到某批不足一批（收敛）或达到批数上限。
     *
     * @param batchStep 单步批处理：入参为本批上限（恒为 {@link NfrTask#CLEANUP_BATCH_SIZE}），
     *                  返回本批实际影响行数
     * @return {@link BatchResult} 累计影响行数 + 是否收敛
     */
    static BatchResult run(IntFunction<Integer> batchStep) {
        int total = 0;
        for (int batch = 0; batch < NfrTask.CLEANUP_MAX_BATCHES; batch++) {
            int affected = batchStep.apply(NfrTask.CLEANUP_BATCH_SIZE);
            total += affected;
            if (affected < NfrTask.CLEANUP_BATCH_SIZE) {
                return new BatchResult(total, true);
            }
        }
        return new BatchResult(total, false);
    }

    /**
     * 分批执行结果。
     *
     * @param affectedRows 累计影响行数
     * @param converged    是否已收敛（{@code false} 表示达到批数上限仍未跑完，须人工关注）
     */
    record BatchResult(int affectedRows, boolean converged) {
    }
}
