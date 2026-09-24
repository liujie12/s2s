package com.s2s.server.common.geo;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

/**
 * {@link GridIdCalculator} 10 条测试向量（[125]；详设 §5.4.1，三端共用同一份）。
 *
 * <p>任一端不过即视为实现错误。第 9 条是唯一能暴露「用截断代替 floor」的向量：
 * 若误用 {@code (long)} 截断，中间微度会得 -1 而非 -2，最终 grid 仍是
 * {@code -1_-1}（结果偶然正确），故必须额外断言中间微度值。</p>
 */
class GridIdCalculatorTest {

    /**
     * 常规正数向量。
     */
    @Test
    void positiveCoordinates() {
        assertThat(GridIdCalculator.of(120.15000, 30.28000)).isEqualTo("26700_6728");
    }

    /**
     * 原点向量。
     */
    @Test
    void origin() {
        assertThat(GridIdCalculator.of(0, 0)).isEqualTo("0_0");
    }

    /**
     * 步长边界（含）。
     */
    @Test
    void stepBoundaryInclusive() {
        assertThat(GridIdCalculator.of(0.00450, 0.00450)).isEqualTo("1_1");
    }

    /**
     * 步长边界（不含）。
     */
    @Test
    void stepBoundaryExclusive() {
        assertThat(GridIdCalculator.of(0.00449, 0.00449)).isEqualTo("0_0");
    }

    /**
     * 负数最小偏移。
     */
    @Test
    void negativeMinOffset() {
        assertThat(GridIdCalculator.of(-0.00001, -0.00001)).isEqualTo("-1_-1");
    }

    /**
     * 负数边界（含）。
     */
    @Test
    void negativeBoundaryInclusive() {
        assertThat(GridIdCalculator.of(-0.00450, -0.00450)).isEqualTo("-1_-1");
    }

    /**
     * 负数跨格。
     */
    @Test
    void negativeCrossCell() {
        assertThat(GridIdCalculator.of(-0.00451, -0.00451)).isEqualTo("-2_-2");
    }

    /**
     * 5 位小数截断。
     */
    @Test
    void fiveDecimalTruncation() {
        assertThat(GridIdCalculator.of(0.004500049, 0.004500049)).isEqualTo("1_1");
    }

    /**
     * 关键探针：负数 floor（非截断）。额外断言中间微度值为 -2。
     */
    @Test
    void negativeFloorProbe() {
        assertThat(GridIdCalculator.of(-0.000015, -0.000015)).isEqualTo("-1_-1");
        // 关键断言：中间微度必须是 -2（floor），截断会得 -1
        assertThat(GridIdCalculator.floorToMicroDegree(-0.000015)).isEqualTo(-2L);
    }

    /**
     * 混合正负向量。
     */
    @Test
    void mixedSignCoordinates() {
        assertThat(GridIdCalculator.of(120.15000, -30.28000)).isEqualTo("26700_-6729");
    }
}
