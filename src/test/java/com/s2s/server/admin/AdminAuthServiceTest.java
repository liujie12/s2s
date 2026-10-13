package com.s2s.server.admin;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.dto.AdminLoginResult;
import com.s2s.server.admin.entity.AdminUserEntity;
import com.s2s.server.admin.mapper.AdminUserMapper;
import com.s2s.server.auth.JwtIssuer;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link AdminAuthService} 单元测试（[153] B2-5）。
 *
 * <p>四类失败一律 40101（禁占错误码 + 防账号枚举）：账号不存在 / 口令错 /
 * 账号禁用 / 角色非法；成功路径签发后台 Token 并回填角色。</p>
 */
class AdminAuthServiceTest {

    /** 账号 Mapper（mock）。 */
    private AdminUserMapper adminUserMapper;

    /** 口令哈希器（mock）。 */
    private AdminPasswordHasher passwordHasher;

    /** JWT 签发器（mock）。 */
    private JwtIssuer jwtIssuer;

    /** 被测服务。 */
    private AdminAuthService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        adminUserMapper = mock(AdminUserMapper.class);
        passwordHasher = mock(AdminPasswordHasher.class);
        jwtIssuer = mock(JwtIssuer.class);
        service = new AdminAuthService(adminUserMapper, passwordHasher, jwtIssuer);
    }

    /**
     * 成功登录：角色合法 → 签发 Token + 回填角色 + 更新最近登录时刻。
     *
     * @return void；断言失败即登录链断裂
     */
    @Test
    void loginSuccessIssuesTokenAndTouchesLastLogin() {
        when(adminUserMapper.selectOne(any())).thenReturn(admin("super_admin", "active"));
        when(passwordHasher.matches(eq("pw"), anyString())).thenReturn(true);
        when(jwtIssuer.issueAdmin(eq(1L), eq("super_admin"))).thenReturn("tok");

        AdminLoginResult result = service.login("root", "pw");

        assertThat(result.token()).isEqualTo("tok");
        assertThat(result.role()).isEqualTo("super_admin");
        verify(adminUserMapper).updateById(any(AdminUserEntity.class));
    }

    /**
     * 账号不存在 → 40101（不区分「不存在」与「口令错」）。
     *
     * @return void；断言失败即账号枚举通道
     */
    @Test
    void loginUnknownUserUnauthorized() {
        when(adminUserMapper.selectOne(any())).thenReturn(null);

        assertThatThrownBy(() -> service.login("nobody", "pw"))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.UNAUTHORIZED);
        verify(jwtIssuer, never()).issueAdmin(anyLong(), anyString());
    }

    /**
     * 口令错 → 40101。
     *
     * @return void
     */
    @Test
    void loginWrongPasswordUnauthorized() {
        when(adminUserMapper.selectOne(any())).thenReturn(admin("super_admin", "active"));
        when(passwordHasher.matches(anyString(), anyString())).thenReturn(false);

        assertThatThrownBy(() -> service.login("root", "bad"))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.UNAUTHORIZED);
    }

    /**
     * 账号禁用 → 40101（与口令错同码，不暴露账号状态）。
     *
     * @return void
     */
    @Test
    void loginDisabledAccountUnauthorized() {
        when(adminUserMapper.selectOne(any())).thenReturn(admin("super_admin", "disabled"));
        when(passwordHasher.matches(anyString(), anyString())).thenReturn(true);

        assertThatThrownBy(() -> service.login("root", "pw"))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.UNAUTHORIZED);
    }

    /**
     * 角色非后台四角色（如历史值 user）→ 40101（不给非法角色发 Token）。
     *
     * @return void
     */
    @Test
    void loginNonAdminRoleUnauthorized() {
        when(adminUserMapper.selectOne(any())).thenReturn(admin("user", "active"));
        when(passwordHasher.matches(anyString(), anyString())).thenReturn(true);

        assertThatThrownBy(() -> service.login("root", "pw"))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.UNAUTHORIZED);
        verify(jwtIssuer, never()).issueAdmin(anyLong(), anyString());
    }

    /**
     * 构造账号行。
     *
     * @param role   角色落库值
     * @param status 账号状态
     * @return {@link AdminUserEntity} 账号行
     */
    private AdminUserEntity admin(String role, String status) {
        AdminUserEntity entity = new AdminUserEntity();
        entity.setId(1L);
        entity.setUsername("root");
        entity.setPasswordHash("pbkdf2$1$a$b");
        entity.setRole(role);
        entity.setStatus(status);
        return entity;
    }
}
