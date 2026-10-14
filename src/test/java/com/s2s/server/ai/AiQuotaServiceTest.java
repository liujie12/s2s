package com.s2s.server.ai;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.s2s.server.category.entity.CategoryEntity;
import com.s2s.server.category.mapper.CategoryMapper;
import com.s2s.server.cert.CertService;
import com.s2s.server.common.constants.NfrAi;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link AiQuotaService} 配额档位解析测试（B2-4；PRD §5.8/§5.10 二维配额表）。
 *
 * <p>覆盖：未实名一律最低档、实名 × 🟢/🟡/🔴 三档、高敏类目 +10。</p>
 */
class AiQuotaServiceTest {

    private CertService certService;
    private CategoryMapper categoryMapper;
    private AiQuotaService service;

    @BeforeEach
    void setUp() {
        certService = mock(CertService.class);
        categoryMapper = mock(CategoryMapper.class);
        AiQuotaGate gate = mock(AiQuotaGate.class);
        service = new AiQuotaService(certService, categoryMapper, gate);
    }

    @Test
    void 未实名一律最低档() {
        when(certService.isRealnamePassed(1L)).thenReturn(false);
        assertThat(service.resolveLimit(1L, 2, null))
                .isEqualTo(NfrAi.QUOTA_UNVERIFIED_OR_RED);
    }

    @Test
    void 实名绿档取20() {
        when(certService.isRealnamePassed(1L)).thenReturn(true);
        assertThat(service.resolveLimit(1L, 2, null))
                .isEqualTo(NfrAi.QUOTA_VERIFIED_GREEN);
    }

    @Test
    void 实名黄档取10() {
        when(certService.isRealnamePassed(1L)).thenReturn(true);
        assertThat(service.resolveLimit(1L, 1, null))
                .isEqualTo(NfrAi.QUOTA_VERIFIED_YELLOW);
    }

    @Test
    void 实名红档取最低档() {
        when(certService.isRealnamePassed(1L)).thenReturn(true);
        assertThat(service.resolveLimit(1L, 0, null))
                .isEqualTo(NfrAi.QUOTA_UNVERIFIED_OR_RED);
    }

    @Test
    void 高敏类目额外加10() {
        when(certService.isRealnamePassed(1L)).thenReturn(true);
        CategoryEntity leaf = new CategoryEntity();
        leaf.setId(10101);
        leaf.setNeedCert("personal_qualification");
        when(categoryMapper.selectById(10101)).thenReturn(leaf);

        assertThat(service.resolveLimit(1L, 2, 10101))
                .isEqualTo(NfrAi.QUOTA_VERIFIED_GREEN + NfrAi.QUOTA_SENSITIVE_BONUS);
    }
}
