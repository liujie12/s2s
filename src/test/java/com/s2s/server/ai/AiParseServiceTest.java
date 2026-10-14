package com.s2s.server.ai;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.ai.dto.AiParseRequest;
import com.s2s.server.ai.dto.AiParseResult;
import com.s2s.server.ai.dto.AiQuota;
import com.s2s.server.category.TemplateService;
import com.s2s.server.category.dto.TemplateDto;
import com.s2s.server.category.dto.TemplateFieldDto;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link AiParseService} 严格 Scope 四步管线测试（B2-4；PRD §5.9/§5.10）。
 *
 * <p><b>核心红线</b>：Step 4 逆向比对——模型编造的实体必须被拒绝注入并移入
 * {@code unresolved_fields}（幻觉 ≈ 0）。另覆盖：合法猜测保留、上游失败回 50301、
 * 输入全空回 40001、配额耗尽回 42901。</p>
 */
class AiParseServiceTest {

    private AiProvider provider;
    private AiQuotaService aiQuotaService;
    private AiQuotaGate aiQuotaGate;
    private TemplateService templateService;
    private AiParseService service;

    @BeforeEach
    void setUp() {
        provider = mock(AiProvider.class);
        aiQuotaService = mock(AiQuotaService.class);
        aiQuotaGate = mock(AiQuotaGate.class);
        templateService = mock(TemplateService.class);
        service = new AiParseService(provider, aiQuotaService, aiQuotaGate, templateService,
                new ObjectMapper());

        when(aiQuotaService.resolveLimit(any(), any(), any())).thenReturn(20);
        when(aiQuotaService.snapshot(any(), anyInt()))
                .thenReturn(new AiQuota(0, 20, Instant.now()));
    }

    /**
     * Step 4 红线：模型编造标题与价格（scope 中无源）→ 一律留空并移入 unresolved_fields。
     */
    @Test
    void 编造字段被拒绝注入() {
        when(provider.generate(anyString(), anyString()))
                .thenReturn("{\"title\":\"纯属编造\",\"price\":999}");

        AiParseResult result = service.parse(1L, req(null, "楼下超市卖苹果", null));

        assertThat(result.guess().title()).isNull();
        assertThat(result.guess().price()).isNull();
        assertThat(result.unresolvedFields()).contains("title", "price");
        assertThat(result.scopeVerified()).doesNotContainKey("title");
    }

    /**
     * 合法猜测保留：标题源于用户文本、价格数字出现在文本中。
     */
    @Test
    void 可溯源猜测保留() {
        when(provider.generate(anyString(), anyString()))
                .thenReturn("{\"title\":\"楼下超市卖苹果\",\"price\":5}");

        AiParseResult result = service.parse(1L, req(null, "楼下超市卖苹果 5 元", null));

        assertThat(result.guess().title()).isEqualTo("楼下超市卖苹果");
        assertThat(result.guess().price()).isEqualTo(5.0);
        assertThat(result.scopeVerified()).containsEntry("title", "user_input")
                .containsEntry("price", "user_input");
        assertThat(result.unresolvedFields()).isEmpty();
    }

    /**
     * 分类仅在等于用户已选叶子类目（P 集合）时保留，来源 platform。
     */
    @Test
    void 分类仅回显已选叶子() {
        when(templateService.getByLeaf(10101)).thenReturn(templateWithFloor());
        when(provider.generate(anyString(), anyString()))
                .thenReturn("{\"leaf_category_id\":10101}");

        AiParseResult result = service.parse(1L, req(10101, "家电维修", null));

        assertThat(result.guess().leafCategoryId()).isEqualTo(10101);
        assertThat(result.scopeVerified()).containsEntry("leaf_category_id", "platform");
    }

    /**
     * 分类编造（与已选叶子不符）→ 拒绝注入。
     */
    @Test
    void 分类不符被拒绝() {
        when(templateService.getByLeaf(10101)).thenReturn(templateWithFloor());
        when(provider.generate(anyString(), anyString()))
                .thenReturn("{\"leaf_category_id\":99999}");

        AiParseResult result = service.parse(1L, req(10101, "家电维修", null));

        assertThat(result.guess().leafCategoryId()).isNull();
        assertThat(result.unresolvedFields()).contains("leaf_category_id");
    }

    /**
     * 模板字段：key 不在模板内或值不在选项内且文本未出现 → 拒绝。
     */
    @Test
    void 模板字段编造被拒绝() {
        when(templateService.getByLeaf(10101)).thenReturn(templateWithFloor());
        when(provider.generate(anyString(), anyString()))
                .thenReturn("{\"template_values\":{\"floor\":\"99层\",\"ghost\":\"x\"}}");

        AiParseResult result = service.parse(1L, req(10101, "家电维修", null));

        assertThat(result.guess().templateValues()).isNull();
        assertThat(result.unresolvedFields()).contains("floor", "ghost");
    }

    /**
     * 模板字段值命中选择项或出现在文本中 → 保留。
     */
    @Test
    void 模板字段合法值保留() {
        when(templateService.getByLeaf(10101)).thenReturn(templateWithFloor());
        when(provider.generate(anyString(), anyString()))
                .thenReturn("{\"template_values\":{\"floor\":\"1层\"}}");

        AiParseResult result = service.parse(1L, req(10101, "家电维修 1层", null));

        assertThat(result.guess().templateValues()).containsEntry("floor", "1层");
    }

    /**
     * 上游不可用 → 50301。
     */
    @Test
    void 上游异常回50301() {
        when(provider.generate(anyString(), anyString()))
                .thenThrow(new IllegalStateException("upstream down"));

        assertThatThrownBy(() -> service.parse(1L, req(null, "家电维修", null)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.AI_UNAVAILABLE);
    }

    /**
     * 四模式输入全空 → 40001。
     */
    @Test
    void 输入全空回40001() {
        assertThatThrownBy(() -> service.parse(1L, req(null, null, null)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    /**
     * 配额耗尽 → 42901。
     */
    @Test
    void 配额耗尽回42901() {
        doThrow(BizException.ofRetryAfter(ErrorCode.AI_QUOTA_EXCEEDED, 100))
                .when(aiQuotaGate).ensureAvailable(any(), anyInt(), any());

        assertThatThrownBy(() -> service.parse(1L, req(null, "家电维修", null)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.AI_QUOTA_EXCEEDED);
    }

    /**
     * 造解析入参（仅用 text 输入，其余可空）。
     *
     * @param leafCategoryId 叶子类目 ID（可空）
     * @param text           用户文本（可空）
     * @param voiceMediaId   音频媒体 ID（可空）
     * @return {@link AiParseRequest} 入参
     */
    private static AiParseRequest req(Integer leafCategoryId, String text, String voiceMediaId) {
        return new AiParseRequest(null, voiceMediaId, null, text, "resource", leafCategoryId, 0);
    }

    /**
     * 带一个 select 模板字段（floor：1层/2层）的模板。
     *
     * @return {@link TemplateDto} 模板
     */
    private static TemplateDto templateWithFloor() {
        TemplateFieldDto floor =
                new TemplateFieldDto("floor", "楼层", "select", false, List.of("1层", "2层"), null, null);
        return new TemplateDto(10101, List.of(floor));
    }
}
