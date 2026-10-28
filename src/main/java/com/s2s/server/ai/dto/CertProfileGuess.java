package com.s2s.server.ai.dto;

/**
 * 证照图抽取结果（AI 域内部产物，对应 AI 供应商的 OCR 能力输出）。
 *
 * <p>字段可为 {@code null}：图片模糊、非证件、模型读不出时返回空值，
 * 由 cert 域转成契约 {@code CertOcrResult}，不视为错误。</p>
 *
 * @param certName 抽取到的证书名称（可空）
 */
public record CertProfileGuess(String certName) {

    /**
     * 空结果（dry-run 或读不出时使用）。
     *
     * @return {@link CertProfileGuess} 证书名为 {@code null}
     */
    public static CertProfileGuess empty() {
        return new CertProfileGuess(null);
    }
}
