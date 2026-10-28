package com.s2s.server.ai.dto;

import java.time.Instant;

/**
 * 证照图抽取结果（AI 域内部产物，对应 AI 供应商的 OCR 能力输出）。
 *
 * <p>两个字段都可为 {@code null}：图片模糊、非证件、模型读不出时返回空值，
 * 由 cert 域转成契约 {@code CertOcrResult}，不视为错误。</p>
 *
 * @param certName 抽取到的证书名称（可空）
 * @param expireAt 抽取到的有效期至（可空；年月落当月最后一天 23:59:59）
 */
public record CertProfileGuess(String certName, Instant expireAt) {

    /**
     * 空结果（dry-run 或读不出时使用）。
     *
     * @return {@link CertProfileGuess} 两字段均为 {@code null}
     */
    public static CertProfileGuess empty() {
        return new CertProfileGuess(null, null);
    }
}
