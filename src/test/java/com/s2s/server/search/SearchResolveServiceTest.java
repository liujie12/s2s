package com.s2s.server.search;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.ai.AiCostLedger;
import com.s2s.server.ai.AiProvider;
import com.s2s.server.category.CategoryService;
import com.s2s.server.post.MediaService;
import com.s2s.server.search.dto.SearchResolveRequest;
import com.s2s.server.search.dto.SearchResolveResult;
import com.s2s.server.search.mapper.CategorySynonymMapper;
import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * 语义解析服务单测（U2）。
 *
 * <p>测试策略：词表/分类/AI/POI/费用台账/媒体全部 Mockito mock，聚焦
 * 「确定性词表短路优先、AI 兜底只补空缺、越界不入槽位」三条核心逻辑。</p>
 */
class SearchResolveServiceTest {

    private CategorySynonymMapper synonymMapper;
    private CategoryService categoryService;
    private AiProvider aiProvider;
    private AmapPoiClient amapPoiClient;
    private CommunityResolver communityResolver;
    private SearchIntentCache intentCache;
    private SearchResolveService service;

    /**
     * 每测前置：装配被 mock 的依赖，词表按 V17 种子的关键行构造。
     */
    @BeforeEach
    void setUp() {
        synonymMapper = mock(CategorySynonymMapper.class);
        categoryService = mock(CategoryService.class);
        aiProvider = mock(AiProvider.class);
        amapPoiClient = mock(AmapPoiClient.class);
        communityResolver = mock(CommunityResolver.class);
        when(communityResolver.resolve(any(), any()))
                .thenReturn(CommunityResolver.CommunityMatch.empty());
        intentCache = mock(SearchIntentCache.class);
        when(intentCache.get(anyString(), any())).thenReturn(null);
        service = new SearchResolveService(synonymMapper, categoryService, aiProvider,
                amapPoiClient, communityResolver, intentCache, mock(AiCostLedger.class),
                mock(MediaService.class),
                new ObjectMapper());

        when(synonymMapper.selectAllEnabled()).thenReturn(List.of(
                new CategorySynonym("租房", "zf", 20101, 95),
                new CategorySynonym("租房", "zf", 20102, 95),
                new CategorySynonym("租房", "zf", 20103, 95),
                new CategorySynonym("合租", "hz", 20101, 95),
                new CategorySynonym("合租", "hz", 20102, 95),
                new CategorySynonym("保洁", "bj", 50101, 95)));
        when(categoryService.categoryPath(any())).thenReturn(List.of("房屋", "整租/合租", "主卧出租"));
        when(categoryService.listLeafOptions()).thenReturn(List.of(
                new CategoryService.LeafOption(20101, "房屋 / 整租/合租 / 主卧出租"),
                new CategoryService.LeafOption(20102, "房屋 / 整租/合租 / 次卧出租"),
                new CategoryService.LeafOption(20103, "房屋 / 整租/合租 / 整租出租")));
        when(aiProvider.transcribe(anyLong(), anyString(), anyString())).thenReturn("");
        // 默认 AI 成功但槽位全空：词表命中的测试仍走词表，但 aiUsed=true（全量走 AI）。
        when(aiProvider.generate(anyLong(), anyString(), anyString())).thenReturn("{}");
    }

    /**
     * 词表命中「租房」仍必须调用 AI（全量走 AI），词表只作为高置信锚点。
     */
    @Test
    void 词表命中租房仍调用AI() {
        SearchResolveResult result = service.resolve(null, req("租房"));

        assertEquals(List.of(20101, 20102, 20103), result.leafCategoryIds());
        assertEquals("vocab", result.sources().get("category"));
        assertTrue(result.aiUsed());
        assertFalse(result.degraded());
        verify(aiProvider).generate(anyLong(), anyString(), anyString());
    }

    /**
     * 缓存命中：直接用缓存里的 AI 输出，不再调用大模型。
     */
    @Test
    void 缓存命中不调用AI() {
        when(intentCache.get(anyString(), any())).thenReturn(
                "{\"post_type\":\"demand\",\"leaf_category_ids\":[20101],"
                        + "\"radius\":\"3\",\"price_min\":null,\"price_max\":null,"
                        + "\"location\":null}");

        SearchResolveResult result = service.resolve(null, req("想找合租"));

        assertTrue(result.aiUsed());
        assertFalse(result.degraded());
        assertEquals("demand", result.postType());
        assertEquals(List.of(20101), result.leafCategoryIds());
        assertEquals("3", result.radius());
        verify(aiProvider, never()).generate(anyLong(), anyString(), anyString());
    }

    /**
     * AI 不可用：不报错，降级词表并标记 degraded。
     */
    @Test
    void AI不可用降级词表且不报错() {
        when(aiProvider.generate(anyLong(), anyString(), anyString()))
                .thenThrow(new IllegalStateException("upstream down"));

        SearchResolveResult result = service.resolve(null, req("1公里内 2000以内 合租"));

        assertFalse(result.aiUsed());
        assertTrue(result.degraded());
        assertEquals("1", result.radius());
        assertEquals(new BigDecimal("2000"), result.priceMax());
        assertEquals(List.of(20101, 20102), result.leafCategoryIds());
    }

    /**
     * AE2：一句话同时命中半径、价格、供需与合租叶子，全程走确定性层。
     */
    @Test
    void 一句话解析半径价格供需与合租叶子() {
        SearchResolveResult result = service.resolve(null, req("1公里内、2000以内、要合租"));

        assertEquals("1", result.radius());
        assertEquals(1000, result.radiusMeters());
        assertEquals(new BigDecimal("2000"), result.priceMax());
        assertNull(result.priceMin());
        assertTrue(result.priceExcludesNegotiable());
        assertEquals("demand", result.postType());
        assertEquals(List.of(20101, 20102), result.leafCategoryIds());
        assertTrue(result.aiUsed());
    }

    /**
     * 中文数字价格「两千以内」归一为 2000。
     */
    @Test
    void 中文数字价格归一() {
        SearchResolveResult result = service.resolve(null, req("两千以内"));

        assertEquals(new BigDecimal("2000"), result.priceMax());
        assertEquals("vocab", result.sources().get("price"));
    }

    /**
     * 未注入高德 Key（POI 恒空）时不抛异常，地点进 unresolved_fields。
     */
    @Test
    void POI未命中不抛异常且地点未解析() {
        when(amapPoiClient.search(anyString())).thenReturn(Optional.empty());

        SearchResolveResult result = service.resolve(null, req("我在锦绣小区要租房"));

        assertNull(result.anchorLng());
        assertTrue(result.unresolvedFields().contains("location"));
        assertEquals(List.of(20101, 20102, 20103), result.leafCategoryIds());
    }

    /**
     * 自由文本走 AI 兜底：越界类目/半径不采用，进 unresolved_fields。
     */
    @Test
    void AI兜底越界字段不采用() {
        when(aiProvider.generate(anyLong(), anyString(), anyString()))
                .thenReturn("{\"post_type\":\"demand\",\"leaf_category_ids\":[99999],"
                        + "\"radius\":\"7\",\"price_min\":null,\"price_max\":3000,"
                        + "\"location\":null}");

        SearchResolveResult result = service.resolve(null, req("离地铁近一点"));

        assertTrue(result.aiUsed());
        assertEquals("demand", result.postType());
        assertTrue(result.leafCategoryIds().isEmpty());
        assertNull(result.radius());
        assertEquals(new BigDecimal("3000"), result.priceMax());
        assertTrue(result.unresolvedFields().contains("category"));
        assertTrue(result.unresolvedFields().contains("radius"));
    }

    /**
     * 无介词口语「北城新徽苑租房」：小区名 + 意图也能抽出地点，并回传小区 ID。
     */
    @Test
    void 无介词小区名解析为小区实体() {
        when(communityResolver.resolve(eq("北城新徽苑"), any()))
                .thenReturn(new CommunityResolver.CommunityMatch("B0FFG001", "新徽苑",
                        117.2, 32.1, List.of(new CommunityResolver.CommunityCandidate(
                                "B0FFG001", "新徽苑", "长丰县", 117.2, 32.1))));

        SearchResolveResult result = service.resolve(null, req("北城新徽苑租房"));

        assertEquals("B0FFG001", result.communityId());
        assertEquals("新徽苑", result.communityName());
        assertEquals(117.2, result.anchorLng(), 1e-9);
        assertEquals(32.1, result.anchorLat(), 1e-9);
        assertEquals(1, result.communityCandidates().size());
        assertEquals(false, result.unresolvedFields().contains("location"));
    }

    /**
     * 长按点与文本小区同时存在：文本小区优先（2026-10-25 用户裁定），
     * 锚点与 community_id 都取小区，长按点不再抢占。
     */
    @Test
    void 文本小区优先于长按点() {
        when(communityResolver.resolve(eq("北城新徽苑"), any()))
                .thenReturn(new CommunityResolver.CommunityMatch("B0FFG001", "新徽苑",
                        117.2, 32.1, List.of()));

        SearchResolveResult result = service.resolve(null, reqWithAnchor("北城新徽苑租房"));

        assertEquals("B0FFG001", result.communityId());
        assertEquals(117.2, result.anchorLng(), 1e-9);
        assertEquals(32.1, result.anchorLat(), 1e-9);
        assertEquals("poi", result.sources().get("anchor"));
    }

    /**
     * 文本小区低置信：保留长按点作锚点，同时回候选让用户点选，且不报「地点没解析」。
     */
    @Test
    void 文本小区低置信保留长按点并回候选() {
        when(communityResolver.resolve(eq("北城新徽苑"), any()))
                .thenReturn(new CommunityResolver.CommunityMatch(null, null, null, null, List.of(
                        new CommunityResolver.CommunityCandidate(
                                "B0FFFT15PD", "北城世纪城鑫徽苑", "长丰县", 117.24, 32.01))));
        when(amapPoiClient.search(anyString())).thenReturn(Optional.empty());

        SearchResolveResult result = service.resolve(null, reqWithAnchor("北城新徽苑租房"));

        assertNull(result.communityId());
        assertEquals(117.0, result.anchorLng(), 1e-9);
        assertEquals(32.0, result.anchorLat(), 1e-9);
        assertEquals("long_press", result.anchorSource());
        assertEquals(1, result.communityCandidates().size());
        assertFalse(result.unresolvedFields().contains("location"));
    }

    /**
     * 构造解析入参（只有文本，无坐标）。
     *
     * @param text 输入文本
     * @return {@link SearchResolveRequest}
     */
    private SearchResolveRequest req(String text) {
        return new SearchResolveRequest(text, null, null, null, null, null, null, null, null);
    }

    /**
     * 构造带长按锚点的解析入参。
     *
     * @param text 输入文本
     * @return {@link SearchResolveRequest}（anchor 117.0/32.0）
     */
    private SearchResolveRequest reqWithAnchor(String text) {
        return new SearchResolveRequest(text, null, null, null, null, 117.0, 32.0, null, null);
    }
}
