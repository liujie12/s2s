package com.s2s.server.ai.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.Map;

/**
 * AI 四件套猜测（B2-4；对应 openapi {@code AiGuess}，PRD §5.9）。
 *
 * <p>四件套 = 标题 / 分类 / 价格 / 模板字段。<b>未猜出的字段为 {@code null} 或缺省</b>
 * （不用空串/0 表示「猜不出」，PRD §5.9「不猜、不编造」）。</p>
 *
 * <p>本 record 仅承载 <b>已通过 Step 4 逆向比对</b>的字段（{@code AiParseService}
 * 负责把越界字段置空并移入 {@code unresolved_fields}，故本对象不含非法值）。</p>
 *
 * @param title          标题（需求态含 §7.4.3 前缀；可空）
 * @param leafCategoryId 三级叶子类目 ID（可空）
 * @param price          价格（元；可空表示面议或未猜出）
 * @param priceUnit      价格单位（可空；无服务端模板来源时仅在用户文本出现时保留）
 * @param templateValues 模板字段猜测（键取自模板 {@code fields[].key}；可空）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AiGuess(
        String title,
        Integer leafCategoryId,
        Double price,
        String priceUnit,
        Map<String, Object> templateValues) {
}
