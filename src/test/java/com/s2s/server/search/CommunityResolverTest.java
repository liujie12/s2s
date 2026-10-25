package com.s2s.server.search;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.s2s.server.common.constants.NfrSearch;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * 小区实体归一测试（口语地址 → 小区 ID）。
 *
 * <p>覆盖：前缀口语自动采用、同音错字不静默猜（回候选）、归一化与相似度。</p>
 */
class CommunityResolverTest {

    private AmapPoiClient amapPoiClient;
    private CommunityResolver resolver;

    /**
     * 每测前置：装配被 mock 的高德客户端。
     */
    @BeforeEach
    void setUp() {
        amapPoiClient = mock(AmapPoiClient.class);
        resolver = new CommunityResolver(amapPoiClient);
    }

    /**
     * 场景一：口语带行政区前缀 → 包含关系达到阈值，自动采用。
     */
    @Test
    void 前缀口语自动采用() {
        when(amapPoiClient.inputTips(eq("北城新徽苑"), any())).thenReturn(List.of(
                new AmapPoiClient.Tip("B0FFG001", "新徽苑", "长丰县", "340121",
                        117.2, 32.1)));

        CommunityResolver.CommunityMatch match = resolver.resolve("北城新徽苑", "340100");

        assertThat(match.communityId()).isEqualTo("B0FFG001");
        assertThat(match.communityName()).isEqualTo("新徽苑");
        assertThat(match.candidates()).hasSize(1);
    }

    /**
     * 场景二：同音错字（鑫/新）相似度低于阈值 → 不猜，回候选让用户点选。
     */
    @Test
    void 同音错字回候选不静默采用() {
        when(amapPoiClient.inputTips(eq("鑫徽苑"), any())).thenReturn(List.of(
                new AmapPoiClient.Tip("B0FFG001", "新徽苑", "长丰县", "340121",
                        117.2, 32.1)));

        CommunityResolver.CommunityMatch match = resolver.resolve("鑫徽苑", "340100");

        assertThat(match.communityId()).isNull();
        assertThat(match.candidates()).hasSize(1);
        assertThat(match.candidates().get(0).name()).isEqualTo("新徽苑");
    }

    /**
     * 场景三：无候选（未配置 Key / 高德无结果）→ 空结果，不抛异常。
     */
    @Test
    void 无候选返回空结果() {
        when(amapPoiClient.inputTips(any(), any())).thenReturn(List.of());

        CommunityResolver.CommunityMatch match = resolver.resolve("不存在的小区", null);

        assertThat(match.communityId()).isNull();
        assertThat(match.candidates()).isEmpty();
    }

    /**
     * 场景四：归一化去全角/空白/标点；相似度包含关系给 0.85。
     */
    @Test
    void 归一化与相似度() {
        assertThat(resolver.normalize(" 北城·新徽苑（一期） ")).isEqualTo("北城新徽苑一期");
        assertThat(resolver.score("北城新徽苑", "新徽苑")).isEqualTo(0.85);
        assertThat(resolver.score("新徽苑", "新徽苑")).isEqualTo(1.0);
        assertThat(resolver.score("新徽苑", "徽苑小区")).isLessThan(0.8);
    }

    /**
     * 真实线上命中（2026-10-25，高德 Web 服务）：口语「北城新徽苑」实际命中的
     * 规范名是「北城世纪城鑫徽苑」。二者既非包含关系，又差一个同音字，
     * 打分应落在 [候选下限, 自动采用阈值) 区间 —— 即回候选让用户确认，而不是静默采用。
     */
    @Test
    void 真实小区简称走候选确认而不是静默采用() {
        double score = resolver.score(
                resolver.normalize("北城新徽苑"), resolver.normalize("北城世纪城鑫徽苑"));

        assertThat(score).isGreaterThanOrEqualTo(NfrSearch.COMMUNITY_MIN_SCORE);
        assertThat(score).isLessThan(NfrSearch.COMMUNITY_AUTO_ACCEPT_SCORE);
    }
}
