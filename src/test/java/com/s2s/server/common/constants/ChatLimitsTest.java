package com.s2s.server.common.constants;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * {@link ChatLimits} 对账守门测试（计划 U1 / KTD12）。
 *
 * <p>期望值刻意写死计划条款里的数字（同 {@code RateLimitThresholdsTest} 范式）：
 * 常量与计划条款漂移时本测试必红。前端 {@code NfrChat} 必须与这里逐值一致，
 * 两侧同值的前提是两处都对着同一份计划数字写死，而不是互相引用。</p>
 */
class ChatLimitsTest {

    /**
     * 治理与生命周期阈值逐值对回计划条款（R5 / R21 / R26）。
     *
     * @return void；断言失败即阈值抄录漂移
     */
    @Test
    @DisplayName("未回复 3 条、隐藏 90 天、申请冷却 7 天、重申 72 小时")
    void governanceWindowsMatchPlan() {
        assertThat(ChatLimits.UNREPLIED_TEXT_LIMIT)
                .as("R26 / K3：对方未回复前最多连发 3 条").isEqualTo(3);
        assertThat(ChatLimits.CONVERSATION_HIDE_AFTER_DAYS)
                .as("R5 / K4：90 天无往来从列表隐藏").isEqualTo(90);
        assertThat(ChatLimits.APPLY_REJECT_COOLDOWN_DAYS)
                .as("R21 / R21a：被拒后 7 天可再次申请").isEqualTo(7);
        assertThat(ChatLimits.APPLY_PENDING_REAPPLY_HOURS)
                .as("R21：待审批超过 72 小时可再提交一次").isEqualTo(72);
    }

    /**
     * 输入与分页阈值自洽：默认值不超过上限、正文列宽与常量一致。
     *
     * @return void；断言失败即分页钳制或长度上限不自洽
     */
    @Test
    @DisplayName("正文上限 500，分页默认不超过上限，角标上限 99")
    void inputAndPagingThresholdsAreSelfConsistent() {
        assertThat(ChatLimits.MESSAGE_CONTENT_MAX_LENGTH)
                .as("与 message.content VARCHAR(500) 列宽一致").isEqualTo(500);
        assertThat(ChatLimits.CONVERSATION_PAGE_DEFAULT_SIZE)
                .as("会话列表默认分页不超过单页上限")
                .isLessThanOrEqualTo(ChatLimits.CONVERSATION_PAGE_MAX_SIZE);
        assertThat(ChatLimits.MESSAGE_PAGE_DEFAULT_SIZE)
                .as("消息分页默认不超过单页上限")
                .isLessThanOrEqualTo(ChatLimits.MESSAGE_PAGE_MAX_SIZE);
        assertThat(ChatLimits.UNREAD_BADGE_MAX)
                .as("R9 / R11：超过 99 显示 99+").isEqualTo(99);
        assertThat(ChatLimits.LIST_PREVIEW_MAX_LENGTH)
                .as("摘要截断长度小于正文上限（摘要只是展示副本）")
                .isLessThan(ChatLimits.MESSAGE_CONTENT_MAX_LENGTH);
    }
}
