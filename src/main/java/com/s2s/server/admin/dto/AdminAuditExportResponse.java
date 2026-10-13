package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 审计导出出参（[153] B2-5；PRD §9.10.1「导出需二次确认」）。
 *
 * <p><b>为什么 CSV 内容放在 JSON 信封的字段里，而不是 {@code text/csv} 直出文件</b>：
 * 本工程全部业务响应经统一套壳器 {@code ResponseBodyWrapper} 包成
 * {@code {code,message,data,request_id}}（架构 §2.1 唯一响应出口）。直接返回
 * {@code ResponseEntity<byte[]>} 会被套成 JSON 而损坏 CSV；而「绕过套壳」需改全局
 * 出口或自行写 servlet 流（前者影响全站、后者与套壳器语义冲突）。故导出以
 * <b>同步返回 CSV 文本</b> 落地：服务端一次性把 CSV 拼好放进 {@code content}，
 * 前端二次确认后保存为 {@code file_name} —— 导出仍是同步的，只是载荷经统一信封承载。</p>
 *
 * @param fileName    建议文件名（含 .csv 后缀）
 * @param contentType 内容类型（固定 {@code text/csv; charset=UTF-8}，供前端设置保存类型）
 * @param content     CSV 正文（RFC 4180；含表头，行尾 {@code \n}）
 * @param rowCount    实际导出行数（不含表头；达到导出上限时 = 上限值）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminAuditExportResponse(
        String fileName,
        String contentType,
        String content,
        int rowCount) {
}
