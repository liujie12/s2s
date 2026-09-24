package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * OSS 直传票据请求（[125]；对应 openapi {@code POST /media/upload/ticket} 请求体）。
 *
 * <p>文件名仅用于记录与后缀推断，<b>不作为对象名</b>（安全方案 §5.1 约束⑤：
 * 对象名服务端生成，客户端不可指定）。</p>
 *
 * @param filename    原始文件名（仅记录，不作为对象名）
 * @param size        文件字节数（超出上限回 40001）
 * @param contentType MIME 类型（须在服务端白名单内）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record UploadTicketRequest(
        @NotBlank @Size(max = 128) String filename,
        @NotNull @Max(Integer.MAX_VALUE) Integer size,
        @NotBlank String contentType) {
}
