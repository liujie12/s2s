package com.s2s.server.admin;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.admin.dto.AdminLoginResult;
import com.s2s.server.admin.entity.AdminUserEntity;
import com.s2s.server.admin.mapper.AdminUserMapper;
import com.s2s.server.auth.JwtIssuer;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.time.LocalDateTime;
import org.springframework.stereotype.Service;

/**
 * 后台登录服务（[153] B2-5；{@code POST /admin/login}）。
 *
 * <p>流程：按登录名取账号 → 口令校验（PBKDF2）→ 状态/角色合法性 → 更新最近登录时刻 →
 * 签发后台 Token（{@code scope=admin} + {@code role}）。</p>
 *
 * <p><b>失败一律 40101</b>（不区分「账号不存在 / 口令错 / 已禁用」）：PRD §12.5 已定案
 * 25 个错误码，**禁占号**（编码红线）；且分开报错会形成账号枚举通道。已禁用账号与
 * 口令错误返回同一码，登录方无法据此探测账号是否存在或状态。</p>
 */
@Service
public class AdminAuthService {

    /** 账号启用状态值（与 DDL {@code admin_user.status} 枚举一致）。 */
    private static final String STATUS_ACTIVE = "active";

    /** 后台账号 Mapper。 */
    private final AdminUserMapper adminUserMapper;

    /** 口令哈希器（唯一哈希/校验实现处）。 */
    private final AdminPasswordHasher passwordHasher;

    /** JWT 签发器（含后台 Token 变体）。 */
    private final JwtIssuer jwtIssuer;

    /**
     * 构造后台登录服务。
     *
     * @param adminUserMapper 后台账号 Mapper
     * @param passwordHasher  口令哈希器
     * @param jwtIssuer       JWT 签发器
     */
    public AdminAuthService(AdminUserMapper adminUserMapper, AdminPasswordHasher passwordHasher,
            JwtIssuer jwtIssuer) {
        this.adminUserMapper = adminUserMapper;
        this.passwordHasher = passwordHasher;
        this.jwtIssuer = jwtIssuer;
    }

    /**
     * 后台登录。
     *
     * @param username 登录名
     * @param password 口令明文
     * @return {@link AdminLoginResult} 后台 Token + 角色
     * @throws BizException 账号不存在 / 口令错 / 账号禁用 / 角色非法 → 40101
     */
    public AdminLoginResult login(String username, String password) {
        AdminUserEntity admin = findByUsername(username);
        if (admin == null || !passwordHasher.matches(password, admin.getPasswordHash())) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        if (!STATUS_ACTIVE.equals(admin.getStatus())) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        OperatorRole role = OperatorRole.fromDbValue(admin.getRole());
        if (role == null || !role.isAdminRole()) {
            // 数据异常（角色非后台四角色）：拒绝登录，不给「以非法角色拿到 Token」的机会
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        touchLastLogin(admin.getId());
        String token = jwtIssuer.issueAdmin(admin.getId(), role.dbValue());
        return new AdminLoginResult(token, role.dbValue());
    }

    /**
     * 按登录名取账号（唯一索引 {@code uk_admin_username} 保证至多一行）。
     *
     * @param username 登录名
     * @return {@link AdminUserEntity} 账号行；不存在返回 {@code null}
     */
    private AdminUserEntity findByUsername(String username) {
        QueryWrapper<AdminUserEntity> wrapper = new QueryWrapper<>();
        wrapper.eq("username", username);
        return adminUserMapper.selectOne(wrapper);
    }

    /**
     * 更新最近登录时刻（只更新该列，避免整行覆盖）。
     *
     * @param adminId 管理员 ID
     */
    private void touchLastLogin(Long adminId) {
        AdminUserEntity patch = new AdminUserEntity();
        patch.setId(adminId);
        patch.setLastLoginAt(LocalDateTime.now());
        adminUserMapper.updateById(patch);
    }
}
