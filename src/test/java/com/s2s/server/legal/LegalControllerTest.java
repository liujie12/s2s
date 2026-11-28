package com.s2s.server.legal;

import static org.assertj.core.api.Assertions.assertThat;

import com.s2s.server.legal.dto.LegalDocumentDto;
import com.s2s.server.legal.dto.LegalDocumentsResponse;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * {@link LegalController} 测试（GAP-01）。
 *
 * <p>只验证控制器把服务结果原样返回（套壳由 {@code ResponseBodyWrapper} 负责，
 * 不在本测试重复断言信封结构）。</p>
 */
class LegalControllerTest {

    /**
     * 控制器返回与 Service 一致的文档清单。
     *
     * @return void；断言失败即控制器未接入服务或做了额外过滤
     */
    @Test
    @DisplayName("GET /legal/documents 返回服务层清单")
    void returnsServiceDocuments() {
        LegalController controller = new LegalController(new LegalService());

        LegalDocumentsResponse response = controller.getLegalDocuments();

        assertThat(response.documents()).hasSize(2);
        assertThat(response.documents().get(0).type()).isEqualTo(LegalService.TYPE_AGREEMENT);
    }

    /**
     * 单文档别名路径返回对应文档。
     *
     * @return void；断言失败即别名未接入服务
     */
    @Test
    @DisplayName("GET /legal/{doc} 返回指定文档")
    void returnsSingleDocument() {
        LegalController controller = new LegalController(new LegalService());

        LegalDocumentDto document = controller.getLegalDocument(LegalService.TYPE_PRIVACY);

        assertThat(document.title()).isEqualTo("隐私政策");
        assertThat(document.url()).isEqualTo("https://zhaoyazhaoapp.com/privacy");
    }
}
