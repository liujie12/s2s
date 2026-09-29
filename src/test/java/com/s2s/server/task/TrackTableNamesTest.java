package com.s2s.server.task;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.YearMonth;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * {@link TrackTableNames} 月表名生成与反解测试（[129] P4；数据库设计 §3.16）。
 *
 * <p>生成与反解必须同源：预建按一种口径命名、清理按另一种口径识别，会让某个月的表永远不被
 * 回收，而这类漂移不报错。故两侧口径都用同一组用例钉住，并覆盖非法输入的 {@code null} 语义
 * （兜底表 {@code track_event_fallback} 不是月表，清理任务必须跳过它而不是试图解析）。</p>
 */
class TrackTableNamesTest {

    /**
     * 生成：年月 → 表名（含补零与跨年）。
     *
     * @return void；断言失败即命名口径漂移
     */
    @Test
    @DisplayName("生成：yyyyMM 补零与跨年")
    void generatesMonthTableName() {
        assertThat(TrackTableNames.of(YearMonth.of(2026, 9))).isEqualTo("track_event_202609");
        assertThat(TrackTableNames.of(YearMonth.of(2026, 12))).isEqualTo("track_event_202612");
        assertThat(TrackTableNames.of(YearMonth.of(2027, 1))).isEqualTo("track_event_202701");
    }

    /**
     * 反解：合法月表名 → 年月；非法形态与兜底表 → {@code null}。
     *
     * @return void；断言失败即清理任务可能误删兜底表或漏删月表
     */
    @Test
    @DisplayName("反解：合法月表名可解析，兜底表与非法形态返回 null")
    void parsesOnlyStrictMonthTables() {
        assertThat(TrackTableNames.parse("track_event_202609")).isEqualTo(YearMonth.of(2026, 9));
        // 兜底表不是月表：清理任务必须跳过它（其数据由搬运任务处理）
        assertThat(TrackTableNames.parse("track_event_fallback")).isNull();
        // 位数不足 / 前缀不符 / 空值
        assertThat(TrackTableNames.parse("track_event_20261")).isNull();
        assertThat(TrackTableNames.parse("track_event_2026091")).isNull();
        assertThat(TrackTableNames.parse("other_event_202609")).isNull();
        assertThat(TrackTableNames.parse(null)).isNull();
    }

    /**
     * 生成与反解互逆（对连续 24 个月验证）。
     *
     * @return void；断言失败即两侧口径不同源
     */
    @Test
    @DisplayName("生成与反解互逆")
    void generateAndParseAreInverse() {
        YearMonth month = YearMonth.of(2026, 1);
        for (int i = 0; i < 24; i++) {
            YearMonth candidate = month.plusMonths(i);
            assertThat(TrackTableNames.parse(TrackTableNames.of(candidate))).isEqualTo(candidate);
        }
    }
}
