package com.s2s.server.legal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.s2s.server.common.error.BizException;
import com.s2s.server.legal.dto.LegalDocumentDto;
import com.s2s.server.legal.dto.LegalDocumentsResponse;
import java.util.List;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * {@link LegalService} 测试（GAP-01）。
 *
 * <p>锁定接口对客户端的可见契约：两份文档、固定顺序、在线 URL、版本号与官网页面一致；
 * 正文不下发（接口只给地址）。</p>
 */
class LegalServiceTest {

    private final LegalService legalService = new LegalService();

    /**
     * 单文档路径按类型返回对应文档（PRD §9 `/legal/{doc}`）。
     *
     * @return void；断言失败即别名返回了错误文档
     */
    @Test
    @DisplayName("单文档路径：agreement / privacy 各返回对应项")
    void getDocumentReturnsMatchingType() {
        assertThat(legalService.getDocument(LegalService.TYPE_AGREEMENT).title()).isEqualTo("用户协议");
        assertThat(legalService.getDocument(LegalService.TYPE_PRIVACY).title()).isEqualTo("隐私政策");
        assertThat(legalService.getDocument(LegalService.TYPE_PRIVACY).version()).isEqualTo("v1.0.0");
    }

    /**
     * 未知类型必须回 40001，不能静默返回空文档。
     *
     * @return void；断言失败即非法入参被当成成功
     */
    @Test
    @DisplayName("单文档路径：未知类型回 40001")
    void getDocumentRejectsUnknownType() {
        assertThatThrownBy(() -> legalService.getDocument("unknown"))
                .isInstanceOf(BizException.class)
                .satisfies(exception -> assertThat(((BizException) exception).getErrorCode().getCode())
                        .isEqualTo(40001));
    }

    /**
     * 返回用户协议 + 隐私政策两份，顺序固定。
     *
     * @return void；断言失败即客户端拿到的文档集合或顺序变化
     */
    @Test
    @DisplayName("返回两份文档：用户协议在前、隐私政策在后")
    void returnsTwoDocumentsInStableOrder() {
        LegalDocumentsResponse response = legalService.listDocuments();

        assertThat(response.documents()).extracting(LegalDocumentDto::type)
                .containsExactly(LegalService.TYPE_AGREEMENT, LegalService.TYPE_PRIVACY);
        assertThat(response.documents()).extracting(LegalDocumentDto::title)
                .containsExactly("用户协议", "隐私政策");
    }

    /**
     * 在线地址必须是自有域名 HTTPS 页面（上架备案与商店登记口径）。
     *
     * @return void；断言失败即返回了非官方地址或非 HTTPS
     */
    @Test
    @DisplayName("在线地址：自有域名 HTTPS")
    void urlsPointToOfficialHttpsPages() {
        List<LegalDocumentDto> docs = legalService.listDocuments().documents();

        assertThat(docs.get(0).url()).isEqualTo("https://zhaoyazhaoapp.com/terms");
        assertThat(docs.get(1).url()).isEqualTo("https://zhaoyazhaoapp.com/privacy");
        assertThat(docs).allSatisfy(doc -> assertThat(doc.url()).startsWith("https://"));
    }

    /**
     * 版本号与生效日期必须与官网页面 doc-meta 一致。
     *
     * @return void；断言失败即协议改版后接口未同步
     */
    @Test
    @DisplayName("版本号与生效日期与官网页面一致")
    void versionsMatchOfficialPages() {
        List<LegalDocumentDto> docs = legalService.listDocuments().documents();

        assertThat(docs.get(0).version()).isEqualTo("v1.1.0");
        assertThat(docs.get(1).version()).isEqualTo("v1.0.0");
        assertThat(docs).allSatisfy(doc -> assertThat(doc.effectiveAt()).isEqualTo("2026-11-05"));
    }

    /**
     * 文档列表必须不可变：调用方修改不能污染后续请求。
     *
     * @return void；断言失败即返回值可被外部篡改
     */
    @Test
    @DisplayName("文档列表不可变")
    void documentListIsImmutable() {
        List<LegalDocumentDto> docs = legalService.listDocuments().documents();

        assertThatThrownBy(() -> docs.add(new LegalDocumentDto(
                "x", "x", "x", "x", "https://example.com")))
                .isInstanceOf(UnsupportedOperationException.class);
    }
}
