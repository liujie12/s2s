package com.s2s.server.legal.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.List;

/**
 * 协议与政策文本清单（对齐 openapi {@code LegalDocumentsResponse}）。
 *
 * @param documents 文档元信息列表（固定顺序：用户协议、隐私政策）
 */
public record LegalDocumentsResponse(
        @JsonProperty("documents") List<LegalDocumentDto> documents
) {
}
