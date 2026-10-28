package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 证照图抽取结果（对应 openapi {@code CertOcrResult}）。
 *
 * <p>{@code certName} 可为 {@code null}：抽取失败不改 HTTP 状态、不报错，由客户端提示
 * 「没读出来，请手动填写」。资质已取消有效期，本结果只回证书名。</p>
 *
 * @param certName 抽取到的证书名称（未读出为 {@code null}）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record CertOcrResult(String certName) {

    /**
     * 空结果（抽取失败/未读出）。
     *
     * @return {@link CertOcrResult} 证名为 {@code null}
     */
    public static CertOcrResult empty() {
        return new CertOcrResult(null);
    }
}
