package com.s2s.server.contact;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

/**
 * {@link ReportRiskScore} 单元测试（[153] B2-5 ④；PRD §9.10.3）。
 *
 * <p>守三件事：① 五类原因基础分与 PRD 逐字一致；② 企业认证 ×1.5；③ 阈值边界
 * （59 不下架 / 60 下架）—— 阈值左右差 1 会直接决定帖子生死，必须钉死。</p>
 */
class ReportRiskScoreTest {

    /**
     * 五类原因基础分 × 普通实名（×1）与 PRD §9.10.3 逐字一致。
     *
     * @return void
     */
    @Test
    void baseScoresMatchPrd() {
        assertThat(ReportRiskScore.of("fraud", false)).isEqualTo(50);
        assertThat(ReportRiskScore.of("false_info", false)).isEqualTo(20);
        assertThat(ReportRiskScore.of("wrong_category", false)).isEqualTo(20);
        assertThat(ReportRiskScore.of("harassment", false)).isEqualTo(10);
        assertThat(ReportRiskScore.of("other", false)).isEqualTo(5);
    }

    /**
     * 企业认证举报方 ×1.5（整数千分比，向下取整）。
     *
     * @return void
     */
    @Test
    void enterpriseReporterGetsOneAndHalfWeight() {
        assertThat(ReportRiskScore.of("fraud", true)).isEqualTo(75);
        assertThat(ReportRiskScore.of("false_info", true)).isEqualTo(30);
        assertThat(ReportRiskScore.of("harassment", true)).isEqualTo(15);
        // 5 × 1.5 = 7.5 → 向下取整 7
        assertThat(ReportRiskScore.of("other", true)).isEqualTo(7);
    }

    /**
     * 未知原因按 {@code other}（5）兜底，不抛异常。
     *
     * @return void
     */
    @Test
    void unknownReasonFallsBackToOther() {
        assertThat(ReportRiskScore.of("unknown_reason", false)).isEqualTo(5);
        assertThat(ReportRiskScore.of(null, false)).isEqualTo(5);
    }

    /**
     * 阈值边界：59 不下架、60 下架（§9.10.3）。
     *
     * @return void
     */
    @Test
    void thresholdBoundaryIsInclusiveAtSixty() {
        assertThat(ReportRiskScore.shouldAutoOffline(59)).isFalse();
        assertThat(ReportRiskScore.shouldAutoOffline(60)).isTrue();
        assertThat(ReportRiskScore.shouldAutoOffline(61)).isTrue();
    }
}
