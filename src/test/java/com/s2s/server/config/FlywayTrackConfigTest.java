package com.s2s.server.config;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * {@link FlywayTrackConfig#withUseAffectedRows(String)} 测试（DEF-06）。
 *
 * <p>埋点库必须以 {@code useAffectedRows=true} 连接：{@code accepted} 是
 * {@code ON DUPLICATE KEY UPDATE id = id} 的净新增行数，Connector/J 默认的 found-rows
 * 语义会让重复行返回 1，导致契约失真。</p>
 */
class FlywayTrackConfigTest {

    /**
     * 无查询参数时用 {@code ?} 追加。
     *
     * @return void；断言失败即 URL 拼接错误
     */
    @Test
    @DisplayName("无查询参数：?useAffectedRows=true")
    void appendsWithQuestionMark() {
        assertThat(FlywayTrackConfig.withUseAffectedRows("jdbc:mysql://mysql:3306/s2s_track"))
                .isEqualTo("jdbc:mysql://mysql:3306/s2s_track?useAffectedRows=true");
    }

    /**
     * 已有查询参数时用 {@code &} 追加，且不破坏既有参数。
     *
     * @return void；断言失败即 URL 拼接错误
     */
    @Test
    @DisplayName("已有查询参数：&useAffectedRows=true")
    void appendsWithAmpersand() {
        assertThat(FlywayTrackConfig.withUseAffectedRows(
                "jdbc:mysql://mysql:3306/s2s_track?sslMode=VERIFY_CA&serverTimezone=Asia/Shanghai"))
                .isEqualTo("jdbc:mysql://mysql:3306/s2s_track?sslMode=VERIFY_CA"
                        + "&serverTimezone=Asia/Shanghai&useAffectedRows=true");
    }

    /**
     * 已显式配置时保持原值，不重复追加。
     *
     * @return void；断言失败即参数重复或覆盖显式配置
     */
    @Test
    @DisplayName("已显式配置：原样返回")
    void keepsExplicitValue() {
        String url = "jdbc:mysql://mysql:3306/s2s_track?useAffectedRows=false";
        assertThat(FlywayTrackConfig.withUseAffectedRows(url)).isEqualTo(url);
    }
}
