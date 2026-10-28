package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 证照图抽取结果（对应 openapi {@code CertOcrResult}）。
 *
 * <p>两个字段都可为 {@code null}：抽取失败不改 HTTP 状态、不报错，由客户端提示
 * 「没读出来，请手动填写」。</p>
 *
 * @param certName 抽取到的证书名称（未读出为 {@code null}）
 * @param expireAt 抽取到的有效期至（未读出为 {@code null}；年月落当月最后一天 23:59:59）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record CertOcrResult(String certName, Instant expireAt) {

    /**
     * 空结果（抽取失败/未读出）。
     *
     * @return {@link CertOcrResult} 两字段均为 {@code null}
     */
    public static CertOcrResult empty() {
        return new CertOcrResult(null, null);
    }
}
