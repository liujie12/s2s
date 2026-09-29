package com.s2s.server.notify;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import com.s2s.server.common.constants.NfrApi;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.notify.dto.NotificationItem;
import com.s2s.server.notify.dto.NotificationTarget;
import com.s2s.server.notify.dto.NotificationsResponse;
import com.s2s.server.notify.mapper.NotificationMapper;
import java.time.Instant;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * {@link NotifyService} 与契约映射测试（[129] P3；详设 §5.6；openapi {@code GET /notifications}）。
 *
 * <p>覆盖三类易错口径：① 契约到库内的字段映射（{@code content}←{@code summary}、
 * {@code is_read}←{@code read_at}）；② 分页钳制与类型白名单（非法 → {@code 40001}）；
 * ③ {@code unread_count} 跨三 Tab 不随筛选收窄。另含 {@link NotifyService#targetOf} 的
 * 纯函数用例与响应 JSON 键名断言（钉死契约键，防 {@code @JsonNaming} 与显式
 * {@code @JsonProperty} 混用时的静默改名）。</p>
 *
 * <p>纯单元测试：Mapper 以 Mockito 替身注入，不连库。</p>
 */
class NotifyServiceTest {

    /** 用户 ID 夹具。 */
    private static final Long USER_ID = 2002L;

    private NotificationMapper mapper;
    private NotifyService service;

    /**
     * 装配替身服务。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        mapper = mock(NotificationMapper.class);
        service = new NotifyService(mapper);
    }

    /**
     * {@code target} 映射：认证通知一律 cert、互动通知带 target_id 才跳帖、系统通知恒 none。
     *
     * @return void；断言失败即客户端会被导到错误页面
     */
    @Test
    @DisplayName("target 映射：cert→认证页、interaction→发布详情、system→无跳转")
    void targetMapping() {
        assertThat(NotifyService.targetOf("cert", 99L))
                .isEqualTo(NotificationTarget.CERT);
        assertThat(NotifyService.targetOf("interaction", 1001L))
                .isEqualTo(NotificationTarget.post(1001L));
        assertThat(NotifyService.targetOf("interaction", null))
                .isEqualTo(NotificationTarget.NONE);
        // system 即使带 target_id 也不猜跳转（PRD §8.3.3 未给 system 跳转规则，见 §2.9 DEC）
        assertThat(NotifyService.targetOf("system", 1001L))
                .isEqualTo(NotificationTarget.NONE);
        // 未知类型（库内枚举外的脏数据）不得抛异常拖垮整页
        assertThat(NotifyService.targetOf("unknown", 1001L))
                .isEqualTo(NotificationTarget.NONE);
    }

    /**
     * 契约字段映射：{@code content} ← {@code summary}、{@code is_read} ← {@code read_at}、
     * 时间列转 UTC {@link Instant}。
     *
     * @return void；断言失败即字段串位（摘要显示成标题、未读标错）
     */
    @Test
    @DisplayName("字段映射：content←summary、is_read←read_at、时间转 UTC Instant")
    void fieldMapping() {
        when(mapper.countByUser(USER_ID, null)).thenReturn(1L);
        when(mapper.selectPage(eq(USER_ID), isNull(), anyInt(), anyInt()))
                .thenReturn(List.of(row(1L, "interaction", "被联系了", "你的发布被联系了 3 次",
                        1001L, "2026-09-29T10:00:00", "2026-09-29T11:00:00")));
        when(mapper.countUnread(USER_ID)).thenReturn(1L);

        NotificationItem item = service.list(USER_ID, null, null, null).items().get(0);

        assertThat(item.content()).isEqualTo("你的发布被联系了 3 次");
        assertThat(item.isRead()).isTrue();
        assertThat(item.createdAt()).isEqualTo(Instant.parse("2026-09-29T10:00:00Z"));
        assertThat(item.target()).isEqualTo(NotificationTarget.post(1001L));
    }

    /**
     * 未读（{@code read_at} 为 null）时 {@code is_read} 为 {@code false}，且
     * {@code content} 为空时返回 {@code null}（不编造空串）。
     *
     * @return void；断言失败即未读态判错
     */
    @Test
    @DisplayName("read_at 为 null → is_read=false；summary 为空 → content=null")
    void unreadAndNullSummary() {
        when(mapper.countByUser(USER_ID, null)).thenReturn(1L);
        when(mapper.selectPage(eq(USER_ID), isNull(), anyInt(), anyInt()))
                .thenReturn(List.of(row(1L, "system", "版本更新", null, null,
                        "2026-09-29T10:00:00", null)));
        when(mapper.countUnread(USER_ID)).thenReturn(1L);

        NotificationItem item = service.list(USER_ID, null, null, null).items().get(0);

        assertThat(item.isRead()).isFalse();
        assertThat(item.content()).isNull();
        assertThat(item.target()).isEqualTo(NotificationTarget.NONE);
    }

    /**
     * 分页钳制：{@code page < 1} 取 1、{@code pageSize} 缺省取默认值、超上限钳到上限，
     * 且偏移量按「钳制后」的值计算。
     *
     * @return void；断言失败即 LIMIT 失去边界或偏移错位
     */
    @Test
    @DisplayName("分页钳制：page/page_size 缺省与上限，offset 按钳制后值计算")
    void paginationClamped() {
        when(mapper.countByUser(USER_ID, null)).thenReturn(0L);
        when(mapper.selectPage(USER_ID, null, 0, NfrApi.PAGE_SIZE_DEFAULT)).thenReturn(List.of());
        when(mapper.countUnread(USER_ID)).thenReturn(0L);

        NotificationsResponse defaults = service.list(USER_ID, null, null, null);
        assertThat(defaults.page()).isEqualTo(1);
        assertThat(defaults.pageSize()).isEqualTo(NfrApi.PAGE_SIZE_DEFAULT);

        when(mapper.selectPage(USER_ID, null, 0, NfrApi.PAGE_SIZE_MAX)).thenReturn(List.of());
        NotificationsResponse oversized = service.list(USER_ID, null, 0, 999);
        assertThat(oversized.page()).isEqualTo(1);
        assertThat(oversized.pageSize()).isEqualTo(NfrApi.PAGE_SIZE_MAX);

        int expectedOffset = (2 - 1) * NfrApi.PAGE_SIZE_MAX;
        when(mapper.selectPage(USER_ID, null, expectedOffset, NfrApi.PAGE_SIZE_MAX))
                .thenReturn(List.of());
        service.list(USER_ID, null, 2, 999);
        verify(mapper).selectPage(USER_ID, null, expectedOffset, NfrApi.PAGE_SIZE_MAX);
    }

    /**
     * 类型筛选：合法线值透传给 Mapper（总数与列表同口径），非法线值 → {@code 40001}
     * 且不触达持久层。
     *
     * @return void；断言失败即非法入参被静默当「全部」处理
     */
    @Test
    @DisplayName("type 筛选：合法值透传、非法值 40001 且不触达 Mapper")
    void typeFilter() {
        when(mapper.countByUser(USER_ID, "interaction")).thenReturn(0L);
        when(mapper.selectPage(eq(USER_ID), eq("interaction"), anyInt(), anyInt()))
                .thenReturn(List.of());
        when(mapper.countUnread(USER_ID)).thenReturn(0L);

        service.list(USER_ID, "interaction", 1, 20);
        verify(mapper).countByUser(USER_ID, "interaction");

        assertThatThrownBy(() -> service.list(USER_ID, "SYSTEM", 1, 20))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isSameAs(ErrorCode.PARAM_INVALID));
    }

    /**
     * {@code unread_count} 跨三 Tab：即使按 {@code type} 筛选，未读数仍取全量口径。
     *
     * @return void；断言失败即 Tab 角标会随切 Tab 跳动
     */
    @Test
    @DisplayName("unread_count 不随 type 收窄（全量未读）")
    void unreadCountIsGlobal() {
        when(mapper.countByUser(USER_ID, "system")).thenReturn(0L);
        when(mapper.selectPage(eq(USER_ID), eq("system"), anyInt(), anyInt())).thenReturn(List.of());
        when(mapper.countUnread(USER_ID)).thenReturn(7L);

        NotificationsResponse response = service.list(USER_ID, "system", 1, 20);

        assertThat(response.unreadCount()).isEqualTo(7L);
        verify(mapper).countUnread(USER_ID);
    }

    /**
     * 响应 JSON 键名钉死契约（{@code is_read} / {@code created_at} / {@code post_id} /
     * {@code unread_count} / {@code page_size}）。
     *
     * <p>本用例的存在理由：{@code is_read} 由显式 {@code @JsonProperty} 承载、其余由
     * {@code @JsonNaming(SnakeCaseStrategy)} 承载，两种机制混用时的静默改名只有序列化实测能发现。</p>
     *
     * @throws Exception JSON 处理失败（测试环境缺陷）
     */
    @Test
    @DisplayName("响应 JSON 键名与契约逐字一致")
    void responseJsonKeysMatchContract() throws Exception {
        NotificationsResponse response = new NotificationsResponse(
                List.of(new NotificationItem(1L, "interaction", "标题", "摘要", false,
                        Instant.parse("2026-09-29T10:00:00Z"), NotificationTarget.post(1001L))),
                1L, 1, 20, 3L);

        JsonNode root = jsonMapper().readTree(jsonMapper().writeValueAsString(response));

        assertThat(fieldNamesOf(root))
                .containsExactlyInAnyOrder("items", "total", "page", "page_size", "unread_count");
        JsonNode item = root.get("items").get(0);
        assertThat(fieldNamesOf(item))
                .containsExactlyInAnyOrder("id", "type", "title", "content", "is_read",
                        "created_at", "target");
        assertThat(fieldNamesOf(item.get("target")))
                .containsExactlyInAnyOrder("kind", "post_id");
    }

    /**
     * 取 JSON 对象的字段名列表（用于键名契约断言）。
     *
     * @param node JSON 对象节点
     * @return {@link List} 字段名（保持序列化顺序）
     */
    private static List<String> fieldNamesOf(JsonNode node) {
        List<String> names = new ArrayList<>();
        node.fieldNames().forEachRemaining(names::add);
        return names;
    }

    /**
     * 构造带 Java 8 时间模块的 {@link ObjectMapper}。
     *
     * <p>运行时用的是 Spring Boot 自动配置的 mapper（已含 jsr310 模块），裸
     * {@code new ObjectMapper()} 默认不认 {@code java.time}；此处显式注册，使断言聚焦
     * 键名契约本身，而不是被「模块未注册」的无关错误顶掉。</p>
     *
     * @return {@link ObjectMapper} 支持 {@code Instant} 序列化
     */
    private static ObjectMapper jsonMapper() {
        return new ObjectMapper().registerModule(new JavaTimeModule());
    }

    /**
     * 构造一行通知夹具（列名与 Mapper XML 出参逐字一致）。
     *
     * @param id        通知 ID
     * @param type      类型线值
     * @param title     标题
     * @param summary   摘要（可空）
     * @param targetId  关联对象 ID（可空）
     * @param createdAt 创建时间（{@code yyyy-MM-ddTHH:mm:ss}，解析为 {@link LocalDateTime}）
     * @param readAt    已读时间（可空即未读）
     * @return {@link Map} 列名 → 值的行数据
     */
    private static Map<String, Object> row(Long id, String type, String title, String summary,
            Long targetId, String createdAt, String readAt) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("id", id);
        row.put("type", type);
        row.put("title", title);
        row.put("summary", summary);
        row.put("target_id", targetId);
        row.put("created_at", LocalDateTime.parse(createdAt));
        row.put("read_at", readAt == null ? null : LocalDateTime.parse(readAt));
        return row;
    }
}
