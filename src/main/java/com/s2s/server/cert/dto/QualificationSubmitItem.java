package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.List;

/**
 * 批量提交中的单条资质（2026-10-28 起一次可提交多张证）。
 *
 * <p>契约见 openapi {@code QualificationSubmitItem}：每组 = 证照图 + 证书名 + 证名来源。</p>
 *
 * @param mediaIds   证照图 media_id 列表（首张作为证照图）
 * @param certName   证书名称（抽取失败且用户未填时为空）
 * @param nameSource 证名来源（{@code ocr}/{@code manual}，可空）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationSubmitItem(
        @NotNull @Size(min = 1) List<String> mediaIds,
        @Size(max = 64) String certName,
        String nameSource) {
}
