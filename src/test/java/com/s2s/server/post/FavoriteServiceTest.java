package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import com.s2s.server.common.constants.NfrApi;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.post.dto.FavoriteItem;
import com.s2s.server.post.dto.FavoritesResponse;
import com.s2s.server.post.dto.MediaItem;
import com.s2s.server.post.entity.PostMediaEntity;
import com.s2s.server.post.mapper.FavoriteMapper;
import com.s2s.server.post.mapper.PostMediaMapper;
import java.math.BigDecimal;
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
 * {@link FavoriteService} 与契约映射测试（[B2-11]；openapi {@code POST/DELETE
 * /posts/{id}/favorite}、{@code GET /favorites}）。
 *
 * <p>覆盖四类易错口径：① 收藏前置（帖子不存在 → {@code 41001} 且不写）；② 列表字段映射与
 * 封面「他人视角」分流（{@code MediaAssembler.toDto(media, false)} 必须被调用）；③
 * {@code type} 白名单（{@code all}/缺省不筛选、非法 → {@code 40001}）；④ 分页钳制与响应
 * JSON 键名契约。</p>
 *
 * <p>纯单元测试：Mapper 与 {@link MediaAssembler} 以 Mockito 替身注入，不连库。</p>
 */
class FavoriteServiceTest {

    /** 用户 ID 夹具。 */
    private static final Long USER_ID = 3003L;

    /** 帖子 ID 夹具。 */
    private static final Long POST_ID = 1001L;

    private FavoriteMapper favoriteMapper;
    private PostMediaMapper postMediaMapper;
    private MediaAssembler mediaAssembler;
    private FavoriteService service;

    /**
     * 装配替身服务。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        favoriteMapper = mock(FavoriteMapper.class);
        postMediaMapper = mock(PostMediaMapper.class);
        mediaAssembler = mock(MediaAssembler.class);
        service = new FavoriteService(favoriteMapper, postMediaMapper, mediaAssembler);
    }

    /**
     * 收藏前置：帖子不存在回 {@code 41001}，且不得触达写路径。
     *
     * @return void；断言失败即会对不存在的帖子写入收藏行
     */
    @Test
    @DisplayName("收藏：帖子不存在 → 41001 且不写")
    void addUnknownPost() {
        when(favoriteMapper.countPostById(POST_ID)).thenReturn(0);

        assertThatThrownBy(() -> service.addFavorite(USER_ID, POST_ID))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isSameAs(ErrorCode.POST_GONE));
        verify(favoriteMapper, never()).upsertFavorite(any(), any());
    }

    /**
     * 收藏成功：回 {@code favorited=true} 且执行 upsert（幂等写）。
     *
     * @return void
     */
    @Test
    @DisplayName("收藏：成功 → favorited=true 且 upsert")
    void addOk() {
        when(favoriteMapper.countPostById(POST_ID)).thenReturn(1);

        assertThat(service.addFavorite(USER_ID, POST_ID).favorited()).isTrue();
        verify(favoriteMapper).upsertFavorite(USER_ID, POST_ID);
    }

    /**
     * 取消收藏：回 {@code favorited=false} 且执行软删（幂等，不校验帖子存在）。
     *
     * @return void
     */
    @Test
    @DisplayName("取消收藏：favorited=false 且软删")
    void removeOk() {
        assertThat(service.removeFavorite(USER_ID, POST_ID).favorited()).isFalse();
        verify(favoriteMapper).softDeleteFavorite(eq(USER_ID), eq(POST_ID), any());
    }

    /**
     * 列表字段映射 + 封面组装（他人视角）。
     *
     * @return void；断言失败即卡片字段串位或封面走了本人视角（下发未过审图）
     */
    @Test
    @DisplayName("列表：字段映射 + 封面他人视角 + 状态派生")
    void listMapping() {
        when(favoriteMapper.countByUser(USER_ID, null)).thenReturn(1L);
        when(favoriteMapper.selectPage(eq(USER_ID), isNull(), anyInt(), anyInt()))
                .thenReturn(List.of(row("resource", "搬家找车", "120.00", "次",
                        "2026-10-01T10:00:00", "2026-10-05T09:00:00")));
        PostMediaEntity media = media(POST_ID);
        when(postMediaMapper.selectList(any())).thenReturn(List.of(media));
        when(mediaAssembler.toDto(media, false))
                .thenReturn(new MediaItem("9", "http://oss/x", "pass", null));

        FavoriteItem item = service.list(USER_ID, null, null, null).items().get(0);

        assertThat(item.postId()).isEqualTo(POST_ID);
        assertThat(item.type()).isEqualTo("resource");
        assertThat(item.leafCategoryId()).isEqualTo(10101);
        assertThat(item.l2CategoryId()).isEqualTo(101);
        assertThat(item.title()).isEqualTo("搬家找车");
        assertThat(item.price()).isEqualByComparingTo("120.00");
        assertThat(item.status()).isEqualTo("active");
        assertThat(item.publishAt()).isEqualTo(Instant.parse("2026-10-01T10:00:00Z"));
        assertThat(item.favoriteAt()).isEqualTo(Instant.parse("2026-10-05T09:00:00Z"));
        assertThat(item.coverMedia()).isNotNull();
        // 视角唯一实现处：收藏者非帖主 → 必须 isOwner=false
        verify(mediaAssembler).toDto(media, false);
    }

    /**
     * {@code type} 白名单：合法值透传、{@code all}/缺省等价不筛选、非法值 {@code 40001}
     * 且不触达持久层。
     *
     * @return void；断言失败即非法入参被静默当「全部」处理
     */
    @Test
    @DisplayName("type 筛选：合法透传、all/缺省不筛选、非法 40001")
    void typeFilter() {
        when(favoriteMapper.countByUser(eq(USER_ID), any())).thenReturn(0L);
        when(favoriteMapper.selectPage(eq(USER_ID), any(), anyInt(), anyInt())).thenReturn(List.of());

        service.list(USER_ID, "demand", 1, 20);
        verify(favoriteMapper).countByUser(USER_ID, "demand");

        service.list(USER_ID, "all", 1, 20);
        service.list(USER_ID, null, 1, 20);
        verify(favoriteMapper, times(2)).countByUser(USER_ID, null);

        assertThatThrownBy(() -> service.list(USER_ID, "RESOURCE", 1, 20))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isSameAs(ErrorCode.PARAM_INVALID));
    }

    /**
     * 分页钳制：{@code page<1} 取 1、{@code pageSize} 缺省取默认、超上限钳到上限，
     * 偏移量按钳制后值计算。
     *
     * @return void；断言失败即 LIMIT 失去边界或偏移错位
     */
    @Test
    @DisplayName("分页钳制：缺省与上限，offset 按钳制后值计算")
    void paginationClamped() {
        when(favoriteMapper.countByUser(eq(USER_ID), any())).thenReturn(0L);
        when(favoriteMapper.selectPage(USER_ID, null, 0, NfrApi.PAGE_SIZE_DEFAULT))
                .thenReturn(List.of());

        FavoritesResponse defaults = service.list(USER_ID, null, null, null);
        assertThat(defaults.page()).isEqualTo(1);
        assertThat(defaults.pageSize()).isEqualTo(NfrApi.PAGE_SIZE_DEFAULT);

        int expectedOffset = (2 - 1) * NfrApi.PAGE_SIZE_MAX;
        when(favoriteMapper.selectPage(USER_ID, null, expectedOffset, NfrApi.PAGE_SIZE_MAX))
                .thenReturn(List.of());
        FavoritesResponse oversized = service.list(USER_ID, null, 2, 999);
        assertThat(oversized.page()).isEqualTo(2);
        assertThat(oversized.pageSize()).isEqualTo(NfrApi.PAGE_SIZE_MAX);
        verify(favoriteMapper).selectPage(USER_ID, null, expectedOffset, NfrApi.PAGE_SIZE_MAX);
    }

    /**
     * 响应 JSON 键名钉死契约（{@code post_id} / {@code favorite_at} / {@code page_size} 等）。
     *
     * @throws Exception JSON 处理失败（测试环境缺陷）
     */
    @Test
    @DisplayName("响应 JSON 键名与契约逐字一致")
    void responseJsonKeysMatchContract() throws Exception {
        FavoritesResponse response = new FavoritesResponse(
                List.of(new FavoriteItem(POST_ID, "resource", 10101, 101, "标题",
                        new BigDecimal("120.00"), "次", null, 0, "active",
                        Instant.parse("2026-10-01T10:00:00Z"),
                        Instant.parse("2026-10-05T09:00:00Z"))),
                1L, 1, 20);

        JsonNode root = jsonMapper().readTree(jsonMapper().writeValueAsString(response));

        assertThat(fieldNamesOf(root)).containsExactlyInAnyOrder("items", "total", "page", "page_size");
        JsonNode item = root.get("items").get(0);
        assertThat(fieldNamesOf(item)).containsExactlyInAnyOrder(
                "post_id", "type", "leaf_category_id", "l2_category_id", "title", "price",
                "price_unit", "cover_media", "completeness_level", "status", "publish_at",
                "favorite_at");
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
     * @return {@link ObjectMapper} 支持 {@code Instant} 序列化
     */
    private static ObjectMapper jsonMapper() {
        return new ObjectMapper().registerModule(new JavaTimeModule());
    }

    /**
     * 构造一行收藏行夹具（列名与 {@code FavoriteMapper.xml} 出参逐字一致）。
     *
     * @param type       供需态线值
     * @param title      标题
     * @param price      价格（可空）
     * @param priceUnit  价格单位
     * @param createdAt  发布时间（{@code yyyy-MM-ddTHH:mm:ss}）
     * @param favoriteAt 收藏时间（同格式）
     * @return {@link Map} 列名 → 值的行数据
     */
    private static Map<String, Object> row(String type, String title, String price, String priceUnit,
            String createdAt, String favoriteAt) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("post_id", POST_ID);
        row.put("type", type);
        row.put("leaf_category_id", 10101);
        row.put("l2_category_id", 101);
        row.put("title", title);
        row.put("price", price == null ? null : new BigDecimal(price));
        row.put("price_unit", priceUnit);
        row.put("completeness_level", 0);
        row.put("status", "active");
        row.put("status_reason", null);
        row.put("created_at", LocalDateTime.parse(createdAt));
        row.put("favorite_at", LocalDateTime.parse(favoriteAt));
        return row;
    }

    /**
     * 构造一条媒体实体夹具（字段值不参与断言，仅作 {@code MediaAssembler} 入参）。
     *
     * @param postId 归属帖子 ID
     * @return {@link PostMediaEntity}
     */
    private static PostMediaEntity media(Long postId) {
        PostMediaEntity entity = new PostMediaEntity();
        entity.setId(9L);
        entity.setPostId(postId);
        entity.setAuditStatus("pass");
        entity.setObjectKey("x");
        return entity;
    }
}
