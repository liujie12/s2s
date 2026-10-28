package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 提交/编辑资质响应（对应 openapi {@code QualificationSubmitResult}）。
 *
 * <p>本轮取消人工审核，提交即生效：{@code status} 为 {@code approved}；
 * 若提交的有效期已过，服务端直接落 {@code expired}。</p>
 *
 * @param certId 资质档案 ID（发布挂载与编辑/删除均以此为准）
 * @param status 提交后状态（{@code approved}/{@code expired}）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationSubmitResult(Long certId, String status) {
}
