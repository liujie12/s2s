package com.s2s.server.task;

import com.s2s.server.common.constants.NfrTempCategory;
import com.s2s.server.ops.TempCategoryService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 72h 临时类目到期结算任务（[153] B2-5 §9.10.2；PRD §9.10.2）。
 *
 * <p>周期性调用 {@link TempCategoryService#settleExpired()}：把已过 {@code expire_at}
 * 的临时类目结算为 {@code promoted}（达标进转正候选池）或 {@code expired}
 * （未达标下线并置分类树禁发）。</p>
 *
 * <p><b>调度周期单源</b>：周期取自 {@link NfrTempCategory#EXPIRE_SCAN_INTERVAL_SECONDS}
 * （秒），此处换算为毫秒后交给 {@code fixedDelay}——故「改动周期」只需改常量一处，
 * 不会出现「常量改了但 cron 串没改」的静默漂移。用 {@code fixedDelay}（上一次执行
 * 结束到下一次开始）而非 {@code fixedRate}，避免结算耗时超过周期时叠加执行。</p>
 */
@Component
public class TempCategoryExpireTask {

    private static final Logger log = LoggerFactory.getLogger(TempCategoryExpireTask.class);

    /** 秒 → 毫秒换算系数（单位换算，非业务阈值）。 */
    private static final long MILLIS_PER_SECOND = 1000L;

    /** 临时类目服务。 */
    private final TempCategoryService tempCategoryService;

    /**
     * 构造临时类目到期结算任务。
     *
     * @param tempCategoryService 临时类目服务
     */
    public TempCategoryExpireTask(TempCategoryService tempCategoryService) {
        this.tempCategoryService = tempCategoryService;
    }

    /**
     * 扫描并结算到期临时类目。
     *
     * @return void；无到期项时不产生日志（常态零输出，避免按周期刷屏）
     */
    @Scheduled(fixedDelay = NfrTempCategory.EXPIRE_SCAN_INTERVAL_SECONDS * MILLIS_PER_SECOND)
    public void settleExpiredTempCategories() {
        int settled = tempCategoryService.settleExpired();
        if (settled > 0) {
            log.info("临时类目到期结算：本次结算 {} 条", settled);
        }
    }
}
