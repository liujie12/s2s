package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import com.s2s.server.common.constants.NfrMedia;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.Size;
import java.util.List;

/**
 * 批量提交资质请求（{@code POST /cert/qualification}；2026-10-28 起一次提交多张证）。
 *
 * <p>数组内每条独立成档；任一条参数非法或证名重复则整批回滚（要么全成要么全不成）。</p>
 *
 * @param items 待提交的资质条目（至少 1 条）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationSubmitRequest(
        @NotEmpty @Size(max = NfrMedia.MAX_MEDIA_COUNT) List<@Valid QualificationSubmitItem> items) {
}
