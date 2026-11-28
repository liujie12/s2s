package com.s2s.server.legal;

import com.s2s.server.legal.dto.LegalDocumentDto;
import com.s2s.server.legal.dto.LegalDocumentsResponse;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

/**
 * 协议与政策域控制器（GAP-01；openapi {@code /legal/documents}）。
 *
 * <p>职责：{@code GET /legal/documents} —— 游客可访问（openapi 声明 {@code security: []}，
 * 无 {@code Authorization} 头即游客态，鉴权在 {@code AuthInterceptor} 完成）。
 * 返回 DTO 由 {@code ResponseBodyWrapper} 统一套壳 {@code ApiResponse}。</p>
 */
@RestController
public class LegalController {

    /** 协议与政策服务（构造注入）。 */
    private final LegalService legalService;

    /**
     * 构造协议域控制器。
     *
     * @param legalService 协议与政策服务
     */
    public LegalController(LegalService legalService) {
        this.legalService = legalService;
    }

    /**
     * 拉取用户协议与隐私政策的元信息（在线地址 + 版本号）。
     *
     * @return {@link LegalDocumentsResponse} 两份文档，顺序固定
     */
    @GetMapping("/legal/documents")
    public LegalDocumentsResponse getLegalDocuments() {
        return legalService.listDocuments();
    }

    /**
     * 按类型拉取单份协议/政策元信息（PRD §9 的 {@code GET /legal/{doc}} 路径）。
     *
     * @param doc 文档类型：{@code agreement} / {@code privacy}
     * @return {@link LegalDocumentDto} 对应文档；未知类型回 {@code 40001}
     */
    @GetMapping("/legal/{doc}")
    public LegalDocumentDto getLegalDocument(@PathVariable("doc") String doc) {
        return legalService.getDocument(doc);
    }
}
