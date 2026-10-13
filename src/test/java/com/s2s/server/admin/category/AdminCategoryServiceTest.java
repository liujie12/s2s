package com.s2s.server.admin.category;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.dto.AdminCategoryCreateRequest;
import com.s2s.server.admin.dto.AdminCategoryListResponse;
import com.s2s.server.admin.dto.AdminCategoryUpdateRequest;
import com.s2s.server.category.CategoryService;
import com.s2s.server.category.entity.CategoryEntity;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link AdminCategoryService} 单元测试（[153] B2-5 ① 分类配置）。
 *
 * <p>守三件事：① RBAC（仅运营专员/超管，其余 40305 且不触达 category 服务）；
 * ② 新增/更新写审计；③ 列表透传可配字段（{@code forbidden}/{@code need_cert}）。</p>
 */
class AdminCategoryServiceTest {

    /** category 域服务（mock）。 */
    private CategoryService categoryService;

    /** 审计写入器（mock）。 */
    private AuditLogWriter auditLogWriter;

    /** 被测服务。 */
    private AdminCategoryService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        categoryService = mock(CategoryService.class);
        auditLogWriter = mock(AuditLogWriter.class);
        service = new AdminCategoryService(categoryService, auditLogWriter);
    }

    /**
     * 运营专员可读列表，可配字段透传。
     *
     * @return void
     */
    @Test
    void operatorListsCategoriesWithConfigFields() {
        CategoryEntity leaf = new CategoryEntity();
        leaf.setId(10101);
        leaf.setParentId(101);
        leaf.setLevel(3);
        leaf.setName("测试叶子");
        leaf.setNeedCert("personal_qualification");
        leaf.setForbidden(1);
        when(categoryService.listAllForAdmin()).thenReturn(List.of(leaf));

        AdminCategoryListResponse response = service.list(OperatorRole.OPERATOR);

        assertThat(response.items()).hasSize(1);
        assertThat(response.items().get(0).forbidden()).isEqualTo(1);
        assertThat(response.items().get(0).needCert()).isEqualTo("personal_qualification");
    }

    /**
     * 内容审核员/算法运营 → 40305，且不触达 category 服务。
     *
     * @return void；断言失败即越权可改分类
     */
    @Test
    void nonOperatorDenied() {
        for (OperatorRole role : new OperatorRole[] {OperatorRole.AUDITOR, OperatorRole.ALGO}) {
            assertThatThrownBy(() -> service.list(role))
                    .as("角色 %s 不应可读分类配置", role)
                    .isInstanceOf(BizException.class)
                    .extracting(e -> ((BizException) e).getErrorCode())
                    .isEqualTo(ErrorCode.NO_PERMISSION);
        }
        verify(categoryService, never()).listAllForAdmin();
    }

    /**
     * 新增叶子类目 → 调域服务 + 写审计。
     *
     * @return void
     */
    @Test
    void createWritesLeafAndAudit() {
        when(categoryService.createLeaf(anyInt(), anyString(), any(), any(), any(), any()))
                .thenReturn(10101);

        service.create(OperatorRole.OPERATOR, 3L,
                new AdminCategoryCreateRequest(101, "新叶子", null, null, 0, 1));

        verify(categoryService).createLeaf(eq(101), eq("新叶子"), any(), any(), eq(0), eq(1));
        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * 更新类目 → 调域服务 + 写审计；越权则两者皆无。
     *
     * @return void
     */
    @Test
    void updateWritesCategoryAndAudit() {
        service.update(OperatorRole.SUPER_ADMIN, 3L, 10101,
                new AdminCategoryUpdateRequest("改名", null, null, 1, 2));

        verify(categoryService).updateCategory(eq(10101), eq("改名"), any(), any(), eq(1), eq(2));
        verify(auditLogWriter).write(any(AuditEntry.class));

        assertThatThrownBy(() -> service.update(OperatorRole.ALGO, 3L, 10101,
                new AdminCategoryUpdateRequest("改名", null, null, null, null)))
                .isInstanceOf(BizException.class);
        verify(categoryService, never()).updateCategory(eq(99999), any(), any(), any(), any(), any());
    }
}
