package com.s2s.server.map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
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
                List.of(10101), "resource", "3", "0_0", "2026-08-31.1",
                120.15, 30.28, null, "publish_time", 2, 20);

        assertEquals(25, resp.total());
        assertEquals(5, resp.items().size());
        assertEquals(2, resp.page());
        assertFalse(resp.categoryVersionStale());
    }
}
