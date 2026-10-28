package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 批量提交资质响应（对应 openapi {@code QualificationBatchSubmitResult}）。
 *
 * <p>顺序与请求 `items` 一致；每条 `status` 恒为 {@code approved}（提交即生效）。</p>
 *
 * @param items 逐条提交结果
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationBatchSubmitResult(List<QualificationSubmitResult> items) {
}
