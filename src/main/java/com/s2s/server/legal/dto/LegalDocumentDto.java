package com.s2s.server.legal.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * 单份协议/政策文本的元信息（对齐 openapi {@code LegalDocument}）。
 *
 * <p>只下发**在线文本地址与版本号**，不内嵌正文：上架手册 P6 要求隐私政策必须挂在
 * 自有域名的独立 URL 上，正文以该 HTML 页面为准（PRD §9「不内嵌写死」）。</p>
 *
 * @param type        文档类型：{@code agreement} 用户协议 / {@code privacy} 隐私政策
 * @param title       展示标题（中文）
 * @param version     文本版本号（与官网页面 {@code doc-meta} 一致）
 * @param effectiveAt 生效日期（ISO-8601 日期，官网页面 {@code doc-meta} 一致）
 * @param url         在线文本地址（HTTPS，自有域名）
 */
public record LegalDocumentDto(
        @JsonProperty("type") String type,
        @JsonProperty("title") String title,
        @JsonProperty("version") String version,
        @JsonProperty("effective_at") String effectiveAt,
        @JsonProperty("url") String url
) {
}
