package com.s2s.server.admin.tempcategory;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.dto.AdminTempCategoryCreateRequest;
import com.s2s.server.admin.dto.AdminTempCategoryListResponse;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.constants.NfrAdmin;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.ops.TempCategoryService;
import com.s2s.server.ops.dto.TempCategoryPage;
import com.s2s.server.ops.dto.TempCategoryView;
import java.time.LocalDateTime;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link AdminTempCategoryService} 单元测试（[153] B2-5 §9.10.2；PRD §9.10.2）。
 *
 * <p>守三件事：① RBAC（仅运营专员/超管，其余 40305 且不触达 ops 服务）；
 * ② 列表透传筛选且分页归一；③ 创建成功后写审计、失败不写。</p>
 */
class AdminTempCategoryServiceTest {

    /** ops 域临时类目服务（mock）。 */
    private TempCategoryService tempCategoryService;

    /** 审计写入器（mock）。 */
    private AuditLogWriter auditLogWriter;

    /** 被测服务。 */
    private AdminTempCategoryService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        tempCategoryService = mock(TempCategoryService.class);
        auditLogWriter = mock(AuditLogWriter.class);
        service = new AdminTempCategoryService(tempCategoryService, auditLogWriter);
    }

    /**
     * 运营专员可读列表；分页归一、快照字段透传。
     *
     * @return void
     */
    @Test
    void operatorListsWithNormalizedPaging() {
        TempCategoryView view = new TempCategoryView(20501, 205, "陪诊", "promoted", 7L,
                LocalDateTime.of(2026, 10, 1, 0, 0), LocalDateTime.of(2026, 10, 4, 0, 0),
                LocalDateTime.of(2026, 10, 4, 0, 5), 4, 6, 1);
        when(tempCategoryService.list(eq("promoted"), eq(1), eq(NfrAdmin.PAGE_SIZE_DEFAULT)))
                .thenReturn(new TempCategoryPage(List.of(view), 1L, 1, NfrAdmin.PAGE_SIZE_DEFAULT));

        AdminTempCategoryListResponse response =
                service.list(OperatorRole.OPERATOR, "promoted", null, null);

        assertThat(response.total()).isEqualTo(1L);
        assertThat(response.items()).hasSize(1);
        assertThat(response.items().get(0).name()).isEqualTo("陪诊");
        assertThat(response.items().get(0).promoted()).isTrue();
        assertThat(response.pageSize()).isEqualTo(NfrAdmin.PAGE_SIZE_DEFAULT);
    }

    /**
     * 内容审核员/算法运营 → 40305，且不触达 ops 服务。
     *
     * @return void；断言失败即越权可读临时类目
     */
    @Test
    void nonOperatorDeniedForList() {
        for (OperatorRole role : new OperatorRole[] {OperatorRole.AUDITOR, OperatorRole.ALGO}) {
            assertThatThrownBy(() -> service.list(role, null, null, null))
                    .as("角色 %s 不应可读临时类目", role)
                    .isInstanceOf(BizException.class)
                    .extracting(e -> ((BizException) e).getErrorCode())
                    .isEqualTo(ErrorCode.NO_PERMISSION);
        }
        verify(tempCategoryService, never()).list(anyString(), anyInt(), anyInt());
    }

    /**
     * 创建成功 → 调域服务 + 写审计（目标 ID = 新建叶子 ID）。
     *
     * @return void
     */
    @Test
    void createWritesAudit() {
        when(tempCategoryService.createTempLeaf(eq(205), eq("陪诊"), eq(5L))).thenReturn(20501);

        service.create(OperatorRole.OPERATOR, 5L, new AdminTempCategoryCreateRequest(205, "陪诊"));

        verify(tempCategoryService).createTempLeaf(eq(205), eq("陪诊"), eq(5L));
        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * 内容审核员不可创建 → 40305，且不触达 ops 服务、不写审计。
     *
     * @return void
     */
    @Test
    void nonOperatorDeniedForCreate() {
        assertThatThrownBy(() -> service.create(OperatorRole.AUDITOR, 5L,
                new AdminTempCategoryCreateRequest(205, "陪诊")))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.NO_PERMISSION);
        verify(tempCategoryService, never()).createTempLeaf(anyInt(), anyString(), anyLong());
        verify(auditLogWriter, never()).write(any());
    }

    /**
     * 域服务抛错（父级非法）→ 不写审计。
     *
     * @return void
     */
    @Test
    void createFailureWritesNoAudit() {
        doThrow(BizException.of(ErrorCode.PARAM_INVALID))
                .when(tempCategoryService).createTempLeaf(anyInt(), anyString(), anyLong());

        assertThatThrownBy(() -> service.create(OperatorRole.OPERATOR, 5L,
                new AdminTempCategoryCreateRequest(999, "陪诊")))
                .isInstanceOf(BizException.class);
        verify(auditLogWriter, never()).write(any());
    }
}
