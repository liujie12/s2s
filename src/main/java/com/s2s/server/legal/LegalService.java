package com.s2s.server.legal;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.legal.dto.LegalDocumentDto;
import com.s2s.server.legal.dto.LegalDocumentsResponse;
import java.util.List;
import org.springframework.stereotype.Service;

/**
 * 协议与政策文本服务（GAP-01；PRD §9 / 上架手册 P6）。
 *
 * <p>职责：为 {@code GET /legal/documents} 提供用户协议与隐私政策的**元信息**。
 * 正文不经过接口下发——两份协议的正式文本已挂在自有域名
 * {@code https://zhaoyazhaoapp.com/terms} 与 {@code /privacy}（2026-11-12 起），
 * 上架备案与商店审核都要求该 URL 可直接访问，接口只负责告诉客户端「去哪看、是什么版本」。</p>
 *
 * <p><b>版本与官网页面保持同源</b>：{@code version}/{@code effective_at} 逐字取自
 * {@code website/terms.html} 与 {@code website/privacy.html} 的 {@code doc-meta}；
 * 协议改版时必须同步这两处，否则客户端展示的版本会与正文不一致。</p>
 */
@Service
public class LegalService {

    /** 用户协议类型值（openapi {@code LegalDocument.type} 枚举）。 */
    static final String TYPE_AGREEMENT = "agreement";

    /** 隐私政策类型值（openapi {@code LegalDocument.type} 枚举）。 */
    static final String TYPE_PRIVACY = "privacy";

    /** 用户协议在线地址（自有域名，备案/商店登记用）。 */
    private static final String AGREEMENT_URL = "https://zhaoyazhaoapp.com/terms";

    /** 隐私政策在线地址（自有域名，备案/商店登记用）。 */
    private static final String PRIVACY_URL = "https://zhaoyazhaoapp.com/privacy";

    /** 用户协议版本号（与 {@code website/terms.html} 的 doc-meta 一致）。 */
    private static final String AGREEMENT_VERSION = "v1.1.0";

    /** 隐私政策版本号（与 {@code website/privacy.html} 的 doc-meta 一致）。 */
    private static final String PRIVACY_VERSION = "v1.0.0";

    /** 两份协议共同的生效日期（与官网页面 doc-meta 一致）。 */
    private static final String EFFECTIVE_AT = "2026-11-05";

    /**
     * 协议清单（不可变；顺序对客户端稳定：先用户协议、后隐私政策）。
     */
    private static final List<LegalDocumentDto> DOCUMENTS = List.of(
            new LegalDocumentDto(TYPE_AGREEMENT, "用户协议", AGREEMENT_VERSION,
                    EFFECTIVE_AT, AGREEMENT_URL),
            new LegalDocumentDto(TYPE_PRIVACY, "隐私政策", PRIVACY_VERSION,
                    EFFECTIVE_AT, PRIVACY_URL));

    /**
     * 返回全部协议与政策文本的元信息。
     *
     * @return {@link LegalDocumentsResponse} 含两份文档（用户协议、隐私政策）
     */
    public LegalDocumentsResponse listDocuments() {
        return new LegalDocumentsResponse(DOCUMENTS);
    }

    /**
     * 按类型取单份协议/政策元信息（PRD §9 {@code GET /legal/{doc}} 口径）。
     *
     * @param doc 文档类型：{@code agreement} / {@code privacy}（大小写敏感）
     * @return {@link LegalDocumentDto} 对应文档元信息
     * @throws BizException 未知类型（{@code 40001} 参数缺失或非法）
     */
    public LegalDocumentDto getDocument(String doc) {
        for (LegalDocumentDto document : DOCUMENTS) {
            if (document.type().equals(doc)) {
                return document;
            }
        }
        throw BizException.of(ErrorCode.PARAM_INVALID);
    }
}
