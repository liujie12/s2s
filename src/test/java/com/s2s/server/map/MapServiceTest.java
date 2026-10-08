package com.s2s.server.map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.category.CategoryService;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.map.dto.PinsCompactResponse;
import com.s2s.server.map.dto.SearchPostsResponse;
import com.s2s.server.map.mapper.MapPostMapper;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * 地图域服务单测（[126]）。
 *
 * <p>测试策略：持久层（{@link MapPostMapper}）与分类服务（{@link CategoryService}）全 Mockito
 * mock，聚焦五要素校验、半径→网格展开、聚合模式判定与紧凑序列化四块纯逻辑。</p>
 */
class MapServiceTest {

    private MapPostMapper mapper;
    private CategoryService categoryService;
    private MapService mapService;

    /**
     * 每测前置：构造 mock 持久层/分类服务，装配被测服务。
     */
    @BeforeEach
    void setUp() {
        mapper = mock(MapPostMapper.class);
        categoryService = mock(CategoryService.class);
        mapService = new MapService(mapper, categoryService);
    }

    /**
     * 场景一：缓存键五要素缺失（category_ids 为 null）→ 40001。
     */
    @Test
    void 五要素缺失回40001() {
        BizException ex = assertThrows(BizException.class, () -> mapService.getPins(
                null, "resource", "3", "0_0", "2026-08-31.1", 120.0, 30.0, 14.0));
        assertEquals(ErrorCode.PARAM_INVALID, ex.getErrorCode());
    }

    /**
     * 场景二：grid_id 正则不符 → 40001。
     */
    @Test
    void gridId正则不符回40001() {
        BizException ex = assertThrows(BizException.class, () -> mapService.getPins(
                List.of(10101), "resource", "3", "abc", "2026-08-31.1", 120.0, 30.0, 14.0));
        assertEquals(ErrorCode.PARAM_INVALID, ex.getErrorCode());
    }

    /**
     * 场景三：半径档非法 → 40001。
     */
    @Test
    void 半径档非法回40001() {
        BizException ex = assertThrows(BizException.class, () -> mapService.getPins(
                List.of(10101), "resource", "2", "0_0", "2026-08-31.1", 120.0, 30.0, 14.0));
        assertEquals(ErrorCode.PARAM_INVALID, ex.getErrorCode());
    }

    /**
     * 场景四：近景（zoom 14.5 → m/px ≈ 5.85 < 30）走 mode=pin，紧凑序列化列序正确。
     */
    @Test
    void 近景返回pin并正确序列化() {
        Map<String, Object> row = Map.of(
                "id", 1001L,
                "lng", new BigDecimal("120.15012"),
                "lat", new BigDecimal("30.28034"),
                "leaf_category_id", 10101,
                "type", "resource",
                "completeness_level", 2);
        when(mapper.selectPins(anyList(), anyList(), anyString(), anyInt()))
                .thenReturn(List.of(row));
        when(mapper.countPins(anyList(), anyList(), anyString())).thenReturn(1L);

        PinsCompactResponse resp = mapService.getPins(
                List.of(10101), "resource", "3", "0_0", "2026-08-31.1", 120.15, 30.28, 14.5);

        assertEquals("pin", resp.mode());
        assertEquals(List.of("id", "lng", "lat", "category_id", "type", "completeness_level"),
                resp.schema());
        // 列序 [id, lng, lat, category_id, type(0=resource), completeness_level]
        assertEquals(List.of(1001L, 120.15012, 30.28034, 10101, 0, 2), resp.pins().get(0));
        assertEquals(1, resp.total());
        assertNull(resp.clusters());
    }

    /**
     * 场景五：远景（zoom 12 → m/px ≈ 33 > 30）走 mode=cluster，服务端预聚合。
     */
    @Test
    void 远景返回cluster() {
        Map<String, Object> clusterRow = Map.of(
                "lng", new BigDecimal("120.15012"),
                "lat", new BigDecimal("30.28034"),
                "count", 3);
        when(mapper.selectClusters(anyList(), anyList(), anyString(), anyInt()))
                .thenReturn(List.of(clusterRow));

        PinsCompactResponse resp = mapService.getPins(
                List.of(10101), "resource", "3", "0_0", "2026-08-31.1", 120.15, 30.28, 12.0);

        assertEquals("cluster", resp.mode());
        assertEquals(3, resp.total());
        assertEquals(120.15012, resp.clusters().get(0).lng());
        assertNull(resp.pins());
    }

    /**
     * 场景六：半径档 city → 网格展开为 null（不过滤 grid_id），透传 mapper。
     */
    @Test
    void 全城半径网格展开为null() {
        when(mapper.selectPins(any(), any(), any(), anyInt())).thenReturn(List.of());
        when(mapper.countPins(any(), any(), any())).thenReturn(0L);

        mapService.getPins(List.of(10101), "resource", "city", "0_0", "2026-08-31.1",
                120.15, 30.28, 14.5);

        verify(mapper).selectPins(isNull(), anyList(), anyString(), anyInt());
    }

    /**
     * 场景七：列表检索分页——候选 25 条、第 2 页 20 条，total 保留全量。
     */
    @Test
    void 列表检索分页与total() {
        List<Map<String, Object>> rows = new java.util.ArrayList<>();
        for (int i = 1; i <= 25; i++) {
            Map<String, Object> row = new java.util.HashMap<>();
            row.put("id", (long) i);
            row.put("type", "resource");
            row.put("leaf_category_id", 10101);
            row.put("l2_category_id", 101);
            row.put("title", "t" + i);
            row.put("summary", "s" + i);
            row.put("lng", new BigDecimal("120.15000"));
            row.put("lat", new BigDecimal("30.28000"));
            row.put("completeness_level", 1);
            row.put("publish_at", java.time.LocalDateTime.of(2026, 9, 1, 12, 0));
            row.put("author_id", 1L);
            row.put("nickname", "n");
            row.put("avatar_url", null);
            row.put("realname_status", "none");
            rows.add(row);
        }
        when(mapper.selectSearchPosts(any(), any(), any(), any())).thenReturn(rows);

        SearchPostsResponse resp = mapService.searchPosts(
                List.of(10101), List.of("resource"), "3", "0_0", "2026-08-31.1",
                120.15, 30.28, null, "publish_time", 2, 20);

        assertEquals(25, resp.total());
        assertEquals(5, resp.items().size());
        assertEquals(2, resp.page());
        assertFalse(resp.categoryVersionStale());
    }

    /**
     * 场景：`/posts/search` 的 `post_type` 多值上界为 2 → 传 3 个回 40001。
     *
     * <p>2026-10-08 `post_type` 由单值扩为 1–2 个。上界必须是硬判定：PRD §6.4.1
     * 只有资源/需求两态，第 3 个值只可能是参数拼错，而拼错的代价是**静默地
     * 少查一类**（`IN` 里多一个不存在的值不报错），故在入口挡住。</p>
     */
    @Test
    void 供需态超过两个回40001() {
        BizException ex = assertThrows(BizException.class, () -> mapService.searchPosts(
                List.of(10101), List.of("resource", "demand", "resource"), "3", "0_0",
                "2026-08-31.1", 120.15, 30.28, null, "distance", 1, 20));
        assertEquals(ErrorCode.PARAM_INVALID, ex.getErrorCode());
    }

    /**
     * 场景八：`composite` 排序的**时效维度**确实参与计算，而非退化成距离排序。
     *
     * <p>构造一对互相矛盾的数据：「近而旧」与「远而新」。若时效项缺失或权重为 0，
     * 综合排序会与距离排序同序，近者恒排第一；含时效项时，远而新者应反超。
     * 两条断言合起来才说明「综合 ≠ 距离」，只看其中一条无法区分。</p>
     */
    @Test
    void 综合排序以时效压过距离() {
        // A：就在视野中心（距离 ≈ 0）但已挂 7 天 → 距离项 0 + 时效项顶格 ≈ 0.5
        Map<String, Object> nearOld = searchRow(1L, "120.15000", "30.28000",
                java.time.LocalDateTime.now().minusDays(7), null);
        // B：正北约 10km（距离项 ≈ 0.5）但刚发布 → 得分 ≈ 0.25，应排到 A 之前
        Map<String, Object> farFresh = searchRow(2L, "120.15000", "30.37000",
                java.time.LocalDateTime.now(), null);
        when(mapper.selectSearchPosts(any(), any(), any(), any()))
                .thenReturn(List.of(nearOld, farFresh));

        // 距离排序：近者在前
        assertEquals(List.of(1L, 2L), fetchedIds("distance"));
        // 综合排序：时效维度生效，远而新者反超近而旧者
        assertEquals(List.of(2L, 1L), fetchedIds("composite"));
    }

    /**
     * 场景九：`price_asc` / `price_desc` 下「面议」（`price = null`）**恒沉底**。
     *
     * <p>把 null 当 0 会让面议在升序里霸占首屏，当极大值则会在降序里霸屏 ——
     * 两个方向都沉底，才符合「不参与价格比较」的语义（与客户端同口径）。</p>
     */
    @Test
    void 价格排序面议恒沉底() {
        java.time.LocalDateTime now = java.time.LocalDateTime.now();
        when(mapper.selectSearchPosts(any(), any(), any(), any())).thenReturn(List.of(
                searchRow(1L, "120.15000", "30.28000", now, new BigDecimal("100.00")),
                searchRow(2L, "120.15000", "30.28000", now, null),
                searchRow(3L, "120.15000", "30.28000", now, new BigDecimal("300.00"))));

        assertEquals(List.of(1L, 3L, 2L), fetchedIds("price_asc"));
        assertEquals(List.of(3L, 1L, 2L), fetchedIds("price_desc"));
    }

    /**
     * 场景十：数值半径按网格边长展开为 (2n+1)² 个候选网格，且**不设人为截断**。
     *
     * <p>n = ceil(半径km × 1000 / 网格边长)，网格边长取
     * {@link com.s2s.server.common.constants.NfrCache#KEY_GRID_METERS}（500m），
     * 故 1/3/5/10km 分别展开 25/169/441/1681 格。半径上界 10km 的 1681 格是线上
     * 真实入参规模：一旦有人在此处加截断或改错系数，候选集会**静默变小**，表现为
     * 「选了大范围反而没点」——这类缺陷只在数据稀疏时暴露，必须由测试钉住。</p>
     */
    @Test
    void 数值半径按网格边长展开() {
        when(mapper.selectSearchPosts(any(), any(), any(), any())).thenReturn(List.of());
        for (String radius : List.of("1", "3", "5", "10")) {
            mapService.searchPosts(List.of(10101), List.of("resource"), radius, "0_0",
                    "2026-08-31.1", 120.15, 30.28, null, "distance", 1, 20);
        }

        ArgumentCaptor<List<String>> captor = ArgumentCaptor.forClass(List.class);
        verify(mapper, times(4)).selectSearchPosts(captor.capture(), anyList(), anyList(), any());

        List<List<String>> captured = captor.getAllValues();
        assertEquals(25, captured.get(0).size());
        assertEquals(169, captured.get(1).size());
        assertEquals(441, captured.get(2).size());
        assertEquals(1681, captured.get(3).size());
        // 展开以中心格为原点，故中心格必在集合内
        assertTrue(captured.get(3).contains("0_0"));
    }

    /**
     * 用固定中心调一次 `/posts/search`，返回结果卡片的 id 顺序。
     *
     * @param sort 排序方式（契约六值之一）
     * @return 结果 id 列表（按服务端返回顺序）
     */
    private List<Long> fetchedIds(String sort) {
        return mapService.searchPosts(List.of(10101), List.of("resource"), "3", "0_0",
                        "2026-08-31.1", 120.15, 30.28, null, sort, 1, 20)
                .items().stream().map(card -> card.id()).toList();
    }

    /**
     * 构造一行 `/posts/search` 候选行（字段名与 `MapPostMapper.selectSearchPosts` 对齐）。
     *
     * @param id        帖子 ID
     * @param lng       经度（字符串，模拟 DECIMAL 取回）
     * @param lat       纬度（同上）
     * @param publishAt 发布时间
     * @param price     价格；null = 面议
     * @return 行映射
     */
    private Map<String, Object> searchRow(long id, String lng, String lat,
            java.time.LocalDateTime publishAt, BigDecimal price) {
        Map<String, Object> row = new java.util.HashMap<>();
        row.put("id", id);
        row.put("type", "resource");
        row.put("leaf_category_id", 10101);
        row.put("l2_category_id", 101);
        row.put("title", "t" + id);
        row.put("summary", "s" + id);
        row.put("price", price);
        row.put("price_unit", price == null ? null : "月");
        row.put("lng", new BigDecimal(lng));
        row.put("lat", new BigDecimal(lat));
        row.put("completeness_level", 1);
        row.put("publish_at", publishAt);
        row.put("author_id", 1L);
        row.put("nickname", "n");
        row.put("avatar_url", null);
        row.put("realname_status", "none");
        return row;
    }
}
