package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 资质档案条目（对应 openapi {@code QualificationItem}）。
 *
 * <p>本人视角的资质档案行：证名、证名来源、状态与证照原件地址。资质已取消类型与有效期，
 * 档案列表与编辑页回填均取自本对象。</p>
 *
 * @param certId     资质档案 ID
 * @param certName   证书名称（可空；历史行为空）
 * @param nameSource 证名来源（{@code ocr}/{@code manual}，可空）
 * @param status     认证状态（本轮恒为 {@code approved}）
 * @param imageUrl   证照原件访问地址（可空；随资质删除失效）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationItem(
        Long certId,
        String certName,
        String nameSource,
        String status,
        String imageUrl) {
}
