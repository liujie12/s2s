package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 提交/编辑资质响应（对应 openapi {@code QualificationSubmitResult}）。
 *
 * <p>本轮取消人工审核，提交即生效：{@code status} 恒为 {@code approved}；
 * 资质已取消有效期，不存在 {@code expired} 状态。</p>
 *
 * @param certId 资质档案 ID（发布挂载与编辑/删除均以此为准）
 * @param status 提交后状态（恒为 {@code approved}）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationSubmitResult(Long certId, String status) {
}
