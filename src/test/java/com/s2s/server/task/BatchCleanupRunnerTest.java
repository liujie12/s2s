package com.s2s.server.task;

import static org.assertj.core.api.Assertions.assertThat;

import com.s2s.server.common.constants.NfrTask;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * {@link BatchCleanupRunner} 分批收敛语义测试（[129] P4）。
 *
 * <p>覆盖三个边界：① 某批不足一批即收敛；② 恰好整批后下一批为空（仍算收敛）；
 * ③ 始终满批时达到迭代上限并返回 {@code converged=false}——第三种是最容易被忽略的一条：
 * 若上限后仍报「已跑完」，运维就永远不会知道有积压。</p>
 */
class BatchCleanupRunnerTest {

    /**
     * 某批返回不足一批 → 立即收敛，且累计行数正确。
     *
     * @return void；断言失败即收敛判定或累计口径错误
     */
    @Test
    @DisplayName("不足一批即收敛")
    void stopsWhenBatchIsNotFull() {
        BatchCleanupRunner.BatchResult result = BatchCleanupRunner.run(limit -> limit - 1);

        assertThat(result.affectedRows()).isEqualTo(NfrTask.CLEANUP_BATCH_SIZE - 1);
        assertThat(result.converged()).isTrue();
    }

    /**
     * 恰好整批后下一批为 0 → 仍算收敛（0 &lt; 一批上限）。
     *
     * @return void；断言失败即「整批收尾」被误判为未收敛
     */
    @Test
    @DisplayName("整批后下一批为空 → 收敛")
    void convergesAfterExactFullBatchFollowedByEmpty() {
        AtomicInteger calls = new AtomicInteger();
        BatchCleanupRunner.BatchResult result = BatchCleanupRunner.run(limit ->
                calls.getAndIncrement() == 0 ? limit : 0);

        assertThat(result.affectedRows()).isEqualTo(NfrTask.CLEANUP_BATCH_SIZE);
        assertThat(result.converged()).isTrue();
        assertThat(calls.get()).isEqualTo(2);
    }

    /**
     * 始终满批 → 达到迭代上限，返回未收敛（不得静默报「已跑完」）。
     *
     * @return void；断言失败即「跑不完」会伪装成成功
     */
    @Test
    @DisplayName("始终满批 → 达到上限并报未收敛")
    void reportsNotConvergedWhenLimitReached() {
        AtomicInteger calls = new AtomicInteger();
        BatchCleanupRunner.BatchResult result = BatchCleanupRunner.run(limit -> {
            calls.incrementAndGet();
            return limit;
        });

        assertThat(result.converged()).isFalse();
        assertThat(result.affectedRows())
                .isEqualTo(NfrTask.CLEANUP_BATCH_SIZE * NfrTask.CLEANUP_MAX_BATCHES);
        assertThat(calls.get()).isEqualTo(NfrTask.CLEANUP_MAX_BATCHES);
    }
}
