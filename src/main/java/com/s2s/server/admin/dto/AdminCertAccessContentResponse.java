package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 打开认证原始信息出参（[153] B2-5；PRD §9.10.1「双人复核通过后方可打开」）。
 *
 * <p>仅在复核通过、且由<b>发起人本人</b>调用时返回；每次打开写审计
 * {@code cert.sensitive_view}。</p>
 *
 * @param certId      目标认证记录 ID
 * @param ocrImageRef 资质图原始引用（{@code cert.ocr_image_ref}；可空表示该记录无资质图）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminCertAccessContentResponse(
        Long certId,
        String ocrImageRef) {
}
