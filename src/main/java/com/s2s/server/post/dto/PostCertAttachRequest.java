package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;
import java.util.List;

/**
 * 发布后补挂 / 替换凭证声明请求（对应 openapi {@code PUT /posts/{post_id}/cert} 请求体）。
 *
 * <p>2026-10-29 起一帖多证：{@code cert_ids} 表示该帖**最终**的资质集合，服务端整体替换；
 * 空数组表示取消全部挂载。</p>
 *
 * @param certIds 本人资质档案 ID 列表（须均为 approved；空数组 = 取消全部挂载）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostCertAttachRequest(@NotNull List<Long> certIds) {
}
