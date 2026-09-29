package com.s2s.server.track.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.constants.NfrApi;
import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.track.TrackPersistence;
import com.s2s.server.track.dto.TrackEventItem;
import com.s2s.server.track.dto.TrackEventItem.EventName;
import com.s2s.server.track.dto.TrackEventRow;
import com.s2s.server.track.dto.TrackEventsRequest;
import com.s2s.server.track.dto.TrackEventsResponse;
import com.s2s.server.track.mapper.TrackEventMapper;
import java.sql.SQLException;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.stereotype.Service;

/**
 * 埋点上报服务（{@code POST /track/events}；详设 §5.8 七步链路）。
 *
 * <p><b>为什么与业务域隔离写入</b>：埋点数据落在独立库 {@code s2s_track}，经
 * {@link TrackPersistence} 取会话；埋点「允许丢、不可用于合规举证」，故<b>不参与业务事务</b>，
 * 也不做重试——写失败按行抛出由上层观测，写成功与否都不影响业务主流程。</p>
 *
 * <p><b>按月分表 + 兜底</b>（详设 §5.8 第 [5] 步）：月表名由<b>客户端上报的 {@code ts}</b>
 * 推导（不使用到达时刻，故 9/30 采集、10/1 上报仍归 202609 表）；表名服务端生成后仍按
 * {@code ^track_event_\d{6}$} 白名单复校（防御性，非信任客户端），不合法即写兜底表
 * {@code track_event_fallback}；写月表返回 MySQL 1146（表不存在，月表预建任务未及）时同样
 * 降级写兜底表，由后台搬运任务按 {@code ts} 归位。</p>
 *
 * <p><b>一致性校验不拒收</b>（第 [6] 步）：{@code layer_switch} 的四段耗时之和与
 * {@code duration_ms} 差异超过 ±1ms 时仅记 WARN，不拒收也不落库标记（Batch1 无数据质量看板）。</p>
 */
@Service
public class TrackService {

    private static final Logger log = LoggerFactory.getLogger(TrackService.class);

    /** 月表名前缀（DDL：{@code track_event_YYYYMM}）。 */
    private static final String MONTH_TABLE_PREFIX = "track_event_";

    /** 跨月/月表缺失时的兜底表名（DDL：{@code track_event_fallback}）。 */
    private static final String FALLBACK_TABLE = "track_event_fallback";

    /** 月表名白名单：仅允许 {@code track_event_} + 六位数字（YYYYMM）。 */
    private static final Pattern MONTH_TABLE_PATTERN = Pattern.compile("^track_event_\\d{6}$");

    /** 月表名中的月份格式（YYYYMM）。 */
    private static final DateTimeFormatter MONTH_FORMAT = DateTimeFormatter.ofPattern("yyyyMM");

    /** MySQL 错误码 1146：表不存在（ER_NO_SUCH_TABLE），据此触发兜底降级。 */
    private static final int MYSQL_ERR_NO_SUCH_TABLE = 1146;

    /** 四段耗时之和与 duration_ms 的允许偏差（毫秒）。 */
    private static final long LAYER_SWITCH_TOLERANCE_MS = 1L;

    /** layer_switch 一致性校验的 props 键。 */
    private static final String KEY_DURATION_MS = "duration_ms";

    /** layer_switch 一致性校验的 props 键。 */
    private static final String KEY_T_CACHE_MS = "t_cache_ms";

    /** layer_switch 一致性校验的 props 键。 */
    private static final String KEY_T_NET_MS = "t_net_ms";

    /** layer_switch 一致性校验的 props 键。 */
    private static final String KEY_T_AGG_MS = "t_agg_ms";

    /** layer_switch 一致性校验的 props 键。 */
    private static final String KEY_T_RENDER_MS = "t_render_ms";

    /** 埋点库月表写入 Mapper（构造期经 {@link TrackPersistence} 取得，非 bean 注入）。 */
    private final TrackEventMapper trackEventMapper;

    /** props 对象 → JSON 文本的唯一序列化入口。 */
    private final ObjectMapper objectMapper;

    /**
     * 构造埋点上报服务。
     *
     * @param trackPersistence 埋点库唯一访问入口（据此取得月表 Mapper）
     * @param objectMapper     事件 {@code props} 的 JSON 序列化器
     */
    public TrackService(TrackPersistence trackPersistence, ObjectMapper objectMapper) {
        this.trackEventMapper = trackPersistence.mapper(TrackEventMapper.class);
        this.objectMapper = objectMapper;
    }

    /**
     * 接收并落库一批埋点事件（详设 §5.8 七步链路：批次上限 → 归月表 → 一致性校验 → 落库）。
     *
     * <p>执行次序（次序即规格）：</p>
     * <ol>
     *   <li>[3] 批次上限：事件数 &gt; {@link NfrApi#TRACK_BATCH_MAX_EVENTS} → {@code 42906}
     *       （needRetryAfter，剩余秒数取限频窗口常量）；</li>
     *   <li>[5] 按客户端 {@code ts} 归月表分组；</li>
     *   <li>[6] {@code layer_switch} 四段耗时和一致性 → 仅 WARN，不拒收；</li>
     *   <li>[7] 逐组写月表，报 1146 时降级写兜底表，累加受影响行数得 {@code accepted}；</li>
     *   <li>{@code dropped_count &gt; 0} 时记一条结构化 WARN（缺口 #5：Batch1 只写日志不落表）。</li>
     * </ol>
     *
     * @param userId   登录用户 ID（调用方以 {@code AuthContext} 保证非 null，不信任请求体用户标识）
     * @param deviceId 设备指纹（请求头 {@code X-Device-Id}，可空）
     * @param request  上报请求（{@code events} 非空）
     * @return {@link TrackEventsResponse} 实际入库事件数
     * @throws BizException {@code 42906} 事件数超批次上限
     */
    public TrackEventsResponse accept(Long userId, String deviceId, TrackEventsRequest request) {
        List<TrackEventItem> events = request.events();

        // [3] 批次上限 → 42906（needRetryAfter；剩余秒数取限频 1 分钟窗常量，见交付说明待确认项）
        if (events.size() > NfrApi.TRACK_BATCH_MAX_EVENTS) {
            throw BizException.ofRetryAfter(ErrorCode.TRACK_LIMIT,
                    RateLimitThresholds.WINDOW_MINUTE_SECONDS);
        }

        // [5] 按客户端 ts 归月表（LinkedHashMap 保持批内出现顺序，落库表序稳定可断言）
        Map<String, List<TrackEventRow>> rowsByTable = new LinkedHashMap<>();
        for (TrackEventItem event : events) {
            // [6] layer_switch 一致性校验：仅 WARN，不影响落库
            checkLayerSwitchConsistency(event);
            rowsByTable.computeIfAbsent(monthTableOf(event.ts()), key -> new ArrayList<>())
                    .add(toRow(event));
        }

        // [7] 逐组落库，累加实际入库行数
        int accepted = 0;
        for (Map.Entry<String, List<TrackEventRow>> entry : rowsByTable.entrySet()) {
            accepted += insertWithFallback(entry.getKey(), entry.getValue(), userId, deviceId);
        }

        // 缺口 #5：客户端丢弃数仅记日志（Batch1 不落表）；仅 &gt;0 时打，避免常态噪声
        int droppedCount = request.droppedCount() == null ? 0 : request.droppedCount();
        if (droppedCount > 0) {
            log.warn("埋点上报存在客户端丢弃：userId={}, droppedCount={}, batchSize={}",
                    userId, droppedCount, events.size());
        }

        return new TrackEventsResponse(accepted);
    }

    /**
     * 计算事件归属的月表名（详设 §5.8 第 [5] 步：按客户端 {@code ts} 归月）。
     *
     * <p>包级可见的静态纯函数，便于单测直接验证跨月与边界映射，无需构造整个服务。</p>
     *
     * @param ts 事件采集时刻
     * @return {@link String} 月表名 {@code track_event_YYYYMM}（UTC 口径）
     */
    public static String monthTableOf(Instant ts) {
        return MONTH_TABLE_PREFIX + MONTH_FORMAT.format(toLocalDateTime(ts));
    }

    /**
     * 把客户端时刻换算为落库用的 {@code DATETIME(3)}（UTC 口径，与 post 域既有约定一致）。
     *
     * @param ts 事件采集时刻
     * @return {@link LocalDateTime} UTC 无时区时间
     */
    static LocalDateTime toLocalDateTime(Instant ts) {
        return LocalDateTime.ofInstant(ts, ZoneOffset.UTC);
    }

    /**
     * 把一条事件转为落库行（props 在此序列化为 JSON 文本）。
     *
     * @param event 事件项
     * @return {@link TrackEventRow} 列值就绪的落库行
     */
    private TrackEventRow toRow(TrackEventItem event) {
        return new TrackEventRow(
                event.event().wire(),
                event.interactionId(),
                toLocalDateTime(event.ts()),
                toPropsJson(event.props()),
                event.leafCategoryId(),
                event.completenessLevel(),
                event.isAiAssisted(),
                event.gridId());
    }

    /**
     * 把 {@code props} 对象序列化为 JSON 文本（月表 {@code props} 列）。
     *
     * @param props 事件属性对象（可空）
     * @return {@link String} JSON 文本；{@code props} 为 null 时返回 null
     * @throws IllegalStateException 序列化失败（写入侧受控，失败即缺陷，不静默落 null）
     */
    private String toPropsJson(Map<String, Object> props) {
        if (props == null) {
            return null;
        }
        try {
            return objectMapper.writeValueAsString(props);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("track.props 序列化失败: " + props, exception);
        }
    }

    /**
     * 写入指定表，遇「表不存在（MySQL 1146）」时降级写兜底表。
     *
     * <p>白名单复校：表名不匹配 {@code ^track_event_\d{6}$} 时改走兜底表（防御性，正常不会触发）。
     * 若目标已是兜底表且仍报 1146，则直接上抛（兜底表本应常驻，缺失属基础设施异常）。</p>
     *
     * @param tableName 目标月表名（服务端生成）
     * @param rows      该表对应的事件行
     * @param userId    登录用户 ID
     * @param deviceId  设备指纹
     * @return int 受影响行数（实际入库事件数）
     */
    private int insertWithFallback(String tableName, List<TrackEventRow> rows,
            Long userId, String deviceId) {
        String safeTable = MONTH_TABLE_PATTERN.matcher(tableName).matches() ? tableName : FALLBACK_TABLE;
        if (!safeTable.equals(tableName)) {
            log.warn("埋点月表名不合法，降级写兜底表：table={}", tableName);
        }
        try {
            return trackEventMapper.batchInsert(safeTable, rows, userId, deviceId);
        } catch (DataAccessException exception) {
            if (!isTableMissing(exception) || FALLBACK_TABLE.equals(safeTable)) {
                throw exception;
            }
            log.warn("埋点月表不存在（1146），降级写兜底表：table={}", safeTable);
            return trackEventMapper.batchInsert(FALLBACK_TABLE, rows, userId, deviceId);
        }
    }

    /**
     * 判定数据访问异常是否为「表不存在（MySQL 1146）」。
     *
     * @param exception 数据访问异常（可能含多层 cause）
     * @return boolean {@code true} 表示异常链中存在 errorCode 1146 的 {@link SQLException}
     */
    private boolean isTableMissing(DataAccessException exception) {
        Throwable cause = exception;
        while (cause != null) {
            if (cause instanceof SQLException sqlException
                    && sqlException.getErrorCode() == MYSQL_ERR_NO_SUCH_TABLE) {
                return true;
            }
            cause = cause.getCause();
        }
        return false;
    }

    /**
     * 校验 {@code layer_switch} 的四段耗时和与 {@code duration_ms} 是否自洽（详设 §5.8 第 [6] 步）。
     *
     * <p>仅对 {@code layer_switch} 生效；四段耗时任一缺失则跳过（不视为异常）。
     * 偏差超过 ±1ms 时记 WARN，<b>不抛异常、不拒收</b>（Batch1 不进数据质量看板）。</p>
     *
     * @param event 事件项
     */
    private void checkLayerSwitchConsistency(TrackEventItem event) {
        if (event.event() != EventName.LAYER_SWITCH || event.props() == null) {
            return;
        }
        Map<String, Object> props = event.props();
        Long duration = asLong(props.get(KEY_DURATION_MS));
        Long cache = asLong(props.get(KEY_T_CACHE_MS));
        Long net = asLong(props.get(KEY_T_NET_MS));
        Long agg = asLong(props.get(KEY_T_AGG_MS));
        Long render = asLong(props.get(KEY_T_RENDER_MS));
        if (duration == null || cache == null || net == null || agg == null || render == null) {
            return;
        }
        long sum = cache + net + agg + render;
        if (Math.abs(sum - duration) > LAYER_SWITCH_TOLERANCE_MS) {
            log.warn("layer_switch 四段耗时和不符：interactionId={}, durationMs={}, sumMs={}",
                    event.interactionId(), duration, sum);
        }
    }

    /**
     * 把 props 中的数值统一转 {@link Long}（JSON 反序列化后可能是 Integer/Long 等）。
     *
     * @param value props 值
     * @return {@link Long}；非数值或 null 时返回 {@code null}
     */
    private Long asLong(Object value) {
        return value instanceof Number number ? number.longValue() : null;
    }
}
