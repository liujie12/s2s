package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.Size;
import java.util.List;

/**
 * 编辑资质请求（对应 openapi {@code PATCH /cert/qualification/{cert_id}} 请求体
 * {@code QualificationUpdateRequest}）。
 *
 * <p>字段全部可选、只改传入项；全为空时由 service 回 40001。换图只替换证照图引用，
 * 不触发服务端重新抽取（抽取由客户端先调 {@code POST /cert/ocr} 完成）。
 * 资质无有效期概念，编辑不涉及状态流转。</p>
 *
 * @param mediaIds   替换证照图 media_id 列表（可空；非空时取首张）
 * @param certName   证书名称（可空；最长 64 字）
 * @param nameSource 证名来源（{@code ocr}/{@code manual}，可空）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationUpdateRequest(
        List<String> mediaIds,
        @Size(max = 64) String certName,
        String nameSource) {

    /**
     * 判断本次编辑是否携带任何可写字段。
     *
     * @return boolean；全部为空时返回 {@code true}（调用方据此回 40001）
     */
    public boolean isEmpty() {
        return mediaIds == null && certName == null && nameSource == null;
    }
}
