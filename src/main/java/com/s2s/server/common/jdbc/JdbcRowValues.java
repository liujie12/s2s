package com.s2s.server.common.jdbc;

import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;

/**
 * JDBC 行取值助手（唯一实现处）。
 *
 * <p>从 MyBatis {@code resultType="map"} 取回的列值，驱动给出的 Java 类型可能是
 * {@code Long}/{@code Integer}/{@code BigDecimal} 等；各域读 service 需要一个统一的
 * 「数值列 → Long/Integer、时间列 → UTC Instant」口径。该逻辑原先在 post 与 notify
 * 两个读 service 中各写一份，本类将其收敛为唯一实现（编码规范 §1.1「同一逻辑第二次
 * 出现即抽公共件」）。</p>
 *
 * <p><b>时间口径</b>：库内 {@code DATETIME} 视为以 UTC 存储，出参统一转 UTC
 * {@link Instant}（与 {@code PostQueryService} 既有实现一致）。</p>
 */
public final class JdbcRowValues {

    /**
     * 私有构造器：工具类禁止实例化（范式同 {@code ErrorCode}）。
     */
    private JdbcRowValues() {
    }

    /**
     * 数值列转 {@link Long}。
     *
     * @param value 列值（{@link Number} 或 null）
     * @return {@link Long}；非数值或 null 时返回 {@code null}
     */
    public static Long toLong(Object value) {
        return value instanceof Number number ? number.longValue() : null;
    }

    /**
     * 数值列转 {@link Integer}。
     *
     * @param value 列值（{@link Number} 或 null）
     * @return {@link Integer}；非数值或 null 时返回 {@code null}
     */
    public static Integer toInteger(Object value) {
        return value instanceof Number number ? number.intValue() : null;
    }

    /**
     * 时间列转 UTC {@link Instant}。
     *
     * @param value 列值（{@link LocalDateTime} 或 null）
     * @return {@link Instant}；非时间值或 null 时返回 {@code null}
     */
    public static Instant toInstant(Object value) {
        return value instanceof LocalDateTime dateTime ? dateTime.toInstant(ZoneOffset.UTC) : null;
    }
}
