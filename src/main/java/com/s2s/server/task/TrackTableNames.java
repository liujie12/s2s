package com.s2s.server.task;

import java.time.YearMonth;
import java.time.format.DateTimeFormatter;
import java.util.regex.Pattern;

/**
 * 埋点月表名工具（[129] P4；抽提依据：编码规范 §1.1——月表名生成与反解在预建、清理、巡检
 * 三处出现，第二次出现即上浮）。
 *
 * <p>月表命名口径的唯一落点：{@code track_event_YYYYMM}（数据库设计 §3.16）。
 * 生成与反解必须同源，否则「预建时按 A 口径命名、清理时按 B 口径识别」会让表名逐渐漂移，
 * 而这类漂移不会报错——只会让某个月的表永远不被回收。</p>
 */
final class TrackTableNames {

    /** 月表名前缀（数据库设计 §3.16 / DDL {@code V1__init_track_schema.sql}）。 */
    private static final String PREFIX = "track_event_";

    /** 月表名后缀月份格式。 */
    private static final DateTimeFormatter MONTH_SUFFIX = DateTimeFormatter.ofPattern("yyyyMM");

    /** 合法月表名的完整形态（前缀 + 六位数字，白名单复校用）。 */
    private static final Pattern VALID_TABLE = Pattern.compile("^track_event_\\d{6}$");

    /**
     * 私有构造器：纯静态工具，无实例状态。
     */
    private TrackTableNames() {
    }

    /**
     * 由年月生成月表名。
     *
     * @param month 年月
     * @return {@link String} 表名，如 {@code track_event_202609}
     */
    static String of(YearMonth month) {
        return PREFIX + month.format(MONTH_SUFFIX);
    }

    /**
     * 由月表名反解年月（仅接受白名单形态，非法返回 {@code null} 由调用方记 WARN 跳过）。
     *
     * @param tableName 表名（可能为 null 或非月表名）
     * @return {@link YearMonth}；非月表名形态时返回 {@code null}
     */
    static YearMonth parse(String tableName) {
        if (tableName == null || !VALID_TABLE.matcher(tableName).matches()) {
            return null;
        }
        return YearMonth.parse(tableName.substring(PREFIX.length()), MONTH_SUFFIX);
    }
}
