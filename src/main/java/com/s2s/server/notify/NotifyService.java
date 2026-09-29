package com.s2s.server.notify;

import com.s2s.server.common.constants.NfrApi;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.notify.dto.NotificationItem;
import com.s2s.server.notify.dto.NotificationTarget;
import com.s2s.server.notify.dto.NotificationsResponse;
import com.s2s.server.notify.mapper.NotificationMapper;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Service;

/**
 * 通知域读服务（[129]；详设 §5.6；openapi {@code GET /notifications}）。
 *
 * <p>Batch1 <b>只有查询</b>：标记已读（{@code POST /notifications/read}）与推送偏好为 Batch2
 * 契约占位，本域不落任何写路径。</p>
 *
 * <p>契约到库内的三处口径（本类完成，不在 Mapper 或 Controller 里写第二次）：
 * <ol>
 *   <li>{@code is_read} ← {@code read_at IS NOT NULL}（库内无布尔列）；</li>
 *   <li>{@code content} ← {@code summary} 列（契约字段名与列名不同）；</li>
 *   <li>{@code target} ← {@code type} + {@code target_id} 派生，见 {@link #targetOf}。</li>
 * </ol></p>
 */
@Service
public class NotifyService {

    private final NotificationMapper notificationMapper;

    /**
     * 构造通知域读服务。
     *
     * @param notificationMapper 通知读 Mapper（三个查询：列表 / 总数 / 未读总数）
     */
    public NotifyService(NotificationMapper notificationMapper) {
        this.notificationMapper = notificationMapper;
    }

    /**
     * 查通知列表（分页 + 类型筛选 + 未读总数）。
     *
     * @param userId   当前登录用户 ID（调用方保证非 null，只取登录态）
     * @param typeParam 类型筛选线值；{@code null} 表示全部，非法值抛 {@code 40001}
     * @param page     页码；{@code null} 或 &lt;1 取 1（对齐 {@code PostQueryService} 既有口径）
     * @param pageSize 每页条数；{@code null} 取 {@link NfrApi#PAGE_SIZE_DEFAULT}，超上限按下限钳制
     * @return {@link NotificationsResponse}
     * @throws BizException {@code 40001} 类型参数不在三值白名单内
     */
    public NotificationsResponse list(Long userId, String typeParam, Integer page, Integer pageSize) {
        NotifyType type = resolveType(typeParam);
        String typeWire = type == null ? null : type.wire();

        int resolvedPage = page == null || page < 1 ? 1 : page;
        // 上限钳制：page_size 无界会让 LIMIT 失去边界（单次请求可拉全表），契约声明 max 50。
        int resolvedPageSize = pageSize == null || pageSize < 1
                ? NfrApi.PAGE_SIZE_DEFAULT
                : Math.min(pageSize, NfrApi.PAGE_SIZE_MAX);

        long total = notificationMapper.countByUser(userId, typeWire);
        List<Map<String, Object>> rows = notificationMapper.selectPage(userId, typeWire,
                (resolvedPage - 1) * resolvedPageSize, resolvedPageSize);

        List<NotificationItem> items = new ArrayList<>(rows.size());
        for (Map<String, Object> row : rows) {
            items.add(new NotificationItem(
                    toLong(row.get("id")),
                    (String) row.get("type"),
                    (String) row.get("title"),
                    (String) row.get("summary"),
                    row.get("read_at") != null,
                    toInstant(row.get("created_at")),
                    targetOf((String) row.get("type"), toLong(row.get("target_id")))));
        }

        // 未读总数跨三 Tab（供 Tab 角标），不随 type 筛选收窄——角标语义见 Mapper 接口注释。
        long unreadCount = notificationMapper.countUnread(userId);
        return new NotificationsResponse(items, total, resolvedPage, resolvedPageSize, unreadCount);
    }

    /**
     * 由库内 {@code type} 与 {@code target_id} 推导契约 {@code target}（纯函数，便于单测）。
     *
     * <p><b>映射口径</b>（依据 PRD §8.3.3「点击通知 → 跳对应详情（被联系 → 跳对应发布详情；
     * 认证 → 跳信任与认证）」）：</p>
     * <ul>
     *   <li>{@code type=cert} → {@code kind=cert}（跳信任与认证页，{@code post_id} 恒 null）；</li>
     *   <li>{@code type=interaction} 且 {@code target_id} 非空 → {@code kind=post}
     *       （"你的发布被联系了"跳该帖详情）；{@code target_id} 为空 → {@code none}；</li>
     *   <li>其余（{@code type=system} 及未知值）→ {@code none}。</li>
     * </ul>
     *
     * <p><b>为什么 system 一律 none（而不是按 target_id 猜）</b>：PRD §8.3.3 只给了「被联系」与
     * 「认证」两条跳转规则，system 类（实名通过／资质通过／违规下架／版本更新）的跳转目标
     * 设计文档未明文；其中「违规下架」直觉上应跳该帖，但没有依据源。按红线
     * 「设计文档未覆盖的口径先问，禁自创口径」，此处取保守的 {@code none}（客户端不跳转，
     * 不会把用户导到错误页面），并已在说明文档 §2.9 登记待裁定。裁定后只需改本方法一处。</p>
     *
     * @param type     库内 {@code notification.type} 线值
     * @param targetId 库内 {@code notification.target_id}（可空）
     * @return {@link NotificationTarget} 恒非 null
     */
    static NotificationTarget targetOf(String type, Long targetId) {
        if (NotifyType.CERT.wire().equals(type)) {
            return NotificationTarget.CERT;
        }
        if (NotifyType.INTERACTION.wire().equals(type)) {
            return targetId == null ? NotificationTarget.NONE : NotificationTarget.post(targetId);
        }
        return NotificationTarget.NONE;
    }

    /**
     * 解析类型入参：{@code null} 表示不筛选，非空非法值抛 {@code 40001}。
     *
     * @param typeParam 类型筛选线值
     * @return {@link NotifyType}；入参为 {@code null} 时返回 {@code null}
     * @throws BizException {@code 40001} 非空但不在 {@code system}/{@code interaction}/{@code cert} 内
     */
    private NotifyType resolveType(String typeParam) {
        if (typeParam == null) {
            return null;
        }
        NotifyType type = NotifyType.fromWire(typeParam);
        if (type == null) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return type;
    }

    /**
     * 把 JDBC 取回的数值列统一转 {@link Long}。
     *
     * @param value 列值（{@code Number} 或 null）
     * @return {@link Long}；非数值或 null 时返回 {@code null}
     */
    private Long toLong(Object value) {
        return value instanceof Number number ? number.longValue() : null;
    }

    /**
     * 把 JDBC 取回的时间列转 UTC {@link Instant}（口径同 {@code PostQueryService}：入库
     * {@code LocalDateTime}、出参 UTC {@code Instant}）。
     *
     * @param value 列值（{@code LocalDateTime} 或 null）
     * @return {@link Instant}；null 时返回 {@code null}
     */
    private Instant toInstant(Object value) {
        return value instanceof LocalDateTime dateTime ? dateTime.toInstant(ZoneOffset.UTC) : null;
    }
}
