package com.s2s.server.admin.template;

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

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.admin.dto.AdminTemplateResponse;
import com.s2s.server.admin.dto.AdminTemplateSaveRequest;
import com.s2s.server.category.TemplateService;
import com.s2s.server.category.entity.TemplateEntity;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link AdminTemplateService} 单元测试（[153] B2-5 ② 模板 Schema 编辑器）。
 *
 * <p>守四件事：① RBAC（仅运营专员/超管，其余 40305 且不触达模板服务）；
 * ② 无自定义模板时返回 {@code version=0 / fields=null}；③ 旧版 JSON 可解析；
 * ④ 保存走版本 +1 并写审计。</p>
 */
class AdminTemplateServiceTest {

    /** category 域模板服务（mock）。 */
    private TemplateService templateService;

    /** 审计写入器（mock）。 */
    private AuditLogWriter auditLogWriter;

    /** 真实 JSON 解析器（被测服务内部用）。 */
    private final ObjectMapper objectMapper = new ObjectMapper();

    /** 被测服务。 */
    private AdminTemplateService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        templateService = mock(TemplateService.class);
        auditLogWriter = mock(AuditLogWriter.class);
        service = new AdminTemplateService(templateService, auditLogWriter, objectMapper);
    }

    /**
     * 无自定义模板 → version=0、fields=null。
     *
     * @return void
     */
    @Test
    void missingTemplateReturnsVersionZero() {
        when(templateService.findRawForAdmin(101)).thenReturn(null);

        AdminTemplateResponse response = service.get(OperatorRole.OPERATOR, 101);

        assertThat(response.templateVersion()).isZero();
        assertThat(response.fields()).isNull();
    }

    /**
     * 已有模板 → 回填版本号与 Schema。
     *
     * @return void
     */
    @Test
    void existingTemplateReturnsVersionAndFields() {
        TemplateEntity entity = new TemplateEntity();
        entity.setLeafCategoryId(101);
        entity.setTemplateVersion(3);
        entity.setFields("[{\"key\":\"price\",\"label\":\"价格\",\"type\":\"number\"}]");
        when(templateService.findRawForAdmin(101)).thenReturn(entity);

        AdminTemplateResponse response = service.get(OperatorRole.OPERATOR, 101);

        assertThat(response.templateVersion()).isEqualTo(3);
        assertThat(response.fields()).hasSize(1);
    }

    /**
     * 算法运营/内容审核员 → 40305，且不触达模板服务。
     *
     * @return void；断言失败即越权可改模板
     */
    @Test
    void nonOperatorDenied() {
        for (OperatorRole role : new OperatorRole[] {OperatorRole.AUDITOR, OperatorRole.ALGO}) {
            assertThatThrownBy(() -> service.get(role, 101))
                    .as("角色 %s 不应可读模板", role)
                    .isInstanceOf(BizException.class)
                    .extracting(e -> ((BizException) e).getErrorCode())
                    .isEqualTo(ErrorCode.NO_PERMISSION);
        }
        verify(templateService, never()).findRawForAdmin(anyInt());
    }

    /**
     * 保存 → 序列化 Schema 调域服务（版本 +1）+ 写审计。
     *
     * @throws Exception JSON 构造异常
     */
    @Test
    void saveSerializesFieldsAndWritesAudit() throws Exception {
        JsonNode fields = objectMapper.readTree("[{\"key\":\"price\"}]");
        when(templateService.saveForAdmin(eq(101), anyString())).thenReturn(2);

        service.save(OperatorRole.OPERATOR, 3L, 101, new AdminTemplateSaveRequest(fields));

        verify(templateService).saveForAdmin(eq(101), anyString());
        verify(auditLogWriter).write(any(AuditEntry.class));
    }
}
