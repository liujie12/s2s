package com.s2s.server.admin.account;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.AdminPasswordHasher;
import com.s2s.server.admin.dto.AdminAccountCreateRequest;
import com.s2s.server.admin.dto.AdminAccountListResponse;
import com.s2s.server.admin.dto.AdminAccountUpdateRequest;
import com.s2s.server.admin.entity.AdminUserEntity;
import com.s2s.server.admin.mapper.AdminUserMapper;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link AdminAccountService} 单元测试（[153] B2-5；PRD §9.10.1 超管「账号与角色管理」）。
 *
 * <p>守四件事：① RBAC（**仅超管**，其余 40305 且不触达 Mapper）；② 新建时口令必须
 * 哈希入库、审计不含明文；③ 口令长度下限；④ 更新空载荷与非法枚举被挡。</p>
 */
class AdminAccountServiceTest {

    /** 账号 Mapper（mock）。 */
    private AdminUserMapper adminUserMapper;

    /** 真实口令哈希器（要验证「入库的是哈希而非明文」）。 */
    private final AdminPasswordHasher passwordHasher = new AdminPasswordHasher();

    /** 审计写入器（mock）。 */
    private AuditLogWriter auditLogWriter;

    /** 被测服务。 */
    private AdminAccountService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        adminUserMapper = mock(AdminUserMapper.class);
        auditLogWriter = mock(AuditLogWriter.class);
        service = new AdminAccountService(adminUserMapper, passwordHasher, auditLogWriter);
    }

    /**
     * 非超管（含内容审核员/运营专员/算法运营）→ 40305，且不触达 Mapper。
     *
     * @return void；断言失败即越权可管理账号
     */
    @Test
    void nonSuperDenied() {
        for (OperatorRole role : new OperatorRole[] {OperatorRole.AUDITOR, OperatorRole.OPERATOR,
                OperatorRole.ALGO}) {
            assertThatThrownBy(() -> service.list(role))
                    .as("角色 %s 不应可管理后台账号", role)
                    .isInstanceOf(BizException.class)
                    .extracting(e -> ((BizException) e).getErrorCode())
                    .isEqualTo(ErrorCode.NO_PERMISSION);
        }
        verify(adminUserMapper, never()).selectList(any());
    }

    /**
     * 新建成功 → 入库为 PBKDF2 哈希（非明文）+ 写审计且审计文本不含口令。
     *
     * @return void；断言失败即出现口令明文落库或落日志（安全红线）
     */
    @Test
    void createStoresHashAndAuditsWithoutPlainPassword() {
        when(adminUserMapper.selectCount(any())).thenReturn(0L);
        when(adminUserMapper.insert(any(AdminUserEntity.class))).thenAnswer(invocation -> {
            AdminUserEntity entity = invocation.getArgument(0);
            entity.setId(5L);
            return 1;
        });

        service.create(OperatorRole.SUPER_ADMIN, 1L,
                new AdminAccountCreateRequest("auditor01", "S3cret-Pass", "auditor"));

        ArgumentCaptor<AdminUserEntity> entityCaptor =
                ArgumentCaptor.forClass(AdminUserEntity.class);
        verify(adminUserMapper).insert(entityCaptor.capture());
        String stored = entityCaptor.getValue().getPasswordHash();
        assertThat(stored).isNotEqualTo("S3cret-Pass").startsWith("pbkdf2$");
        assertThat(stored).doesNotContain("S3cret-Pass");

        ArgumentCaptor<AuditEntry> auditCaptor = ArgumentCaptor.forClass(AuditEntry.class);
        verify(auditLogWriter).write(auditCaptor.capture());
        assertThat(String.valueOf(auditCaptor.getValue())).doesNotContain("S3cret-Pass");
    }

    /**
     * 口令过短 / 角色非法 / 用户名重复 → 40001。
     *
     * @return void
     */
    @Test
    void createRejectsInvalidInput() {
        // 口令过短
        assertThatThrownBy(() -> service.create(OperatorRole.SUPER_ADMIN, 1L,
                new AdminAccountCreateRequest("u1", "short", "auditor")))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);

        // 角色非法（system 非后台可分配角色）
        assertThatThrownBy(() -> service.create(OperatorRole.SUPER_ADMIN, 1L,
                new AdminAccountCreateRequest("u1", "longenough1", "system")))
                .isInstanceOf(BizException.class);

        // 用户名重复
        when(adminUserMapper.selectCount(any())).thenReturn(1L);
        assertThatThrownBy(() -> service.create(OperatorRole.SUPER_ADMIN, 1L,
                new AdminAccountCreateRequest("dup", "longenough1", "auditor")))
                .isInstanceOf(BizException.class);

        verify(adminUserMapper, never()).insert(any(AdminUserEntity.class));
    }

    /**
     * 更新空载荷 / 非法状态 → 40001；合法更新写审计（含变更前值）。
     *
     * @return void
     */
    @Test
    void updateValidatesPayload() {
        AdminUserEntity existing = new AdminUserEntity();
        existing.setId(9L);
        existing.setRole("auditor");
        existing.setStatus("active");
        when(adminUserMapper.selectById(9L)).thenReturn(existing);

        assertThatThrownBy(() -> service.update(OperatorRole.SUPER_ADMIN, 1L, 9L,
                new AdminAccountUpdateRequest(null, null)))
                .isInstanceOf(BizException.class);

        assertThatThrownBy(() -> service.update(OperatorRole.SUPER_ADMIN, 1L, 9L,
                new AdminAccountUpdateRequest(null, "frozen")))
                .isInstanceOf(BizException.class);

        service.update(OperatorRole.SUPER_ADMIN, 1L, 9L,
                new AdminAccountUpdateRequest("operator", "disabled"));

        verify(adminUserMapper).updateById(any(AdminUserEntity.class));
        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * 重置口令：过短 → 40001；账号不存在 → 41001；成功则写审计且不含明文。
     *
     * @return void
     */
    @Test
    void resetPasswordGuardsAndAudits() {
        assertThatThrownBy(() -> service.resetPassword(OperatorRole.SUPER_ADMIN, 1L, 9L, "short"))
                .isInstanceOf(BizException.class);

        when(adminUserMapper.selectById(9L)).thenReturn(null);
        assertThatThrownBy(() -> service.resetPassword(OperatorRole.SUPER_ADMIN, 1L, 9L,
                "longenough1"))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);

        AdminUserEntity existing = new AdminUserEntity();
        existing.setId(9L);
        when(adminUserMapper.selectById(9L)).thenReturn(existing);
        service.resetPassword(OperatorRole.SUPER_ADMIN, 1L, 9L, "longenough1");

        ArgumentCaptor<AuditEntry> auditCaptor = ArgumentCaptor.forClass(AuditEntry.class);
        verify(auditLogWriter).write(auditCaptor.capture());
        assertThat(String.valueOf(auditCaptor.getValue())).doesNotContain("longenough1");
    }

    /**
     * 列表出参不含口令哈希字段（结构上只有白名单字段）。
     *
     * @return void
     */
    @Test
    void listReturnsWhitelistedFields() {
        AdminUserEntity entity = new AdminUserEntity();
        entity.setId(3L);
        entity.setUsername("boss");
        entity.setRole("super_admin");
        entity.setStatus("active");
        entity.setPasswordHash("pbkdf2$secret");
        when(adminUserMapper.selectList(any())).thenReturn(List.of(entity));

        AdminAccountListResponse response = service.list(OperatorRole.SUPER_ADMIN);

        assertThat(response.items()).hasSize(1);
        assertThat(response.items().get(0).username()).isEqualTo("boss");
        assertThat(response.items().get(0).toString()).doesNotContain("pbkdf2$secret");
    }
}
