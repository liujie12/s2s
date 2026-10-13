package com.s2s.server.admin.account;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.admin.AdminPasswordHasher;
import com.s2s.server.admin.dto.AdminAccountCreateRequest;
import com.s2s.server.admin.dto.AdminAccountListResponse;
import com.s2s.server.admin.dto.AdminAccountUpdateRequest;
import com.s2s.server.admin.entity.AdminUserEntity;
import com.s2s.server.admin.mapper.AdminUserMapper;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.constants.NfrAdmin;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.time.ZoneOffset;
import java.util.List;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 后台账号与角色管理服务（[153] B2-5；PRD §9.10.1 角色表「超级管理员：全部 + 账号与角色管理」）。
 *
 * <p><b>RBAC</b>：本页是 PRD 明文归给超级管理员的<b>唯一</b>专属能力——仅
 * {@link OperatorRole#SUPER_ADMIN} 可操作，其余角色（含内容审核员/运营专员/算法运营）
 * 一律 {@code 40305}。</p>
 *
 * <p><b>口令纪律</b>（编码规范 §4.11 安全红线）：口令只经 {@link AdminPasswordHasher}
 * 哈希后入库，<b>审计与日志中永不出现口令明文或哈希</b>（审计只记「哪个账号被重置」）。</p>
 *
 * <p><b>审计</b>：账号新建/改角色改状态/重置口令均写 {@code audit_log}（PRD §9.10.1
 * 「其操作同样全量留痕」），与落库同事务。</p>
 *
 * <p><b>未加的自守规则</b>：PRD 未定义「超管能否禁用自己/最后一个超管」，故本服务
 * <b>不自创</b>该限制（自创口径会让「文档没写的行为」变成隐式契约）；如需要，
 * 属产品侧裁定后补。</p>
 */
@Service
public class AdminAccountService {

    /** 审计动作：新建后台账号。 */
    static final String ACTION_ACCOUNT_CREATE = "admin.account.create";

    /** 审计动作：修改后台账号（角色/状态）。 */
    static final String ACTION_ACCOUNT_UPDATE = "admin.account.update";

    /** 审计动作：重置后台账号口令。 */
    static final String ACTION_ACCOUNT_PASSWORD_RESET = "admin.account.password_reset";

    /** 审计目标类型：后台账号。 */
    static final String TARGET_ADMIN_USER = "admin_user";

    /** 账号状态：启用。 */
    private static final String STATUS_ACTIVE = "active";

    /** 账号状态：禁用。 */
    private static final String STATUS_DISABLED = "disabled";

    /** 账号 Mapper（admin 域自有）。 */
    private final AdminUserMapper adminUserMapper;

    /** 口令哈希器（PBKDF2，库内唯一口令处理入口）。 */
    private final AdminPasswordHasher passwordHasher;

    /** 审计写入器（唯一写入处）。 */
    private final AuditLogWriter auditLogWriter;

    /**
     * 构造后台账号服务。
     *
     * @param adminUserMapper admin_user Mapper
     * @param passwordHasher  口令哈希器
     * @param auditLogWriter  审计写入器
     */
    public AdminAccountService(AdminUserMapper adminUserMapper, AdminPasswordHasher passwordHasher,
            AuditLogWriter auditLogWriter) {
        this.adminUserMapper = adminUserMapper;
        this.passwordHasher = passwordHasher;
        this.auditLogWriter = auditLogWriter;
    }

    /**
     * 列出全部后台账号。
     *
     * <p>用 {@code selectList}（不分页）而非 SQL 分页：后台账号是**个位数量级**的
     * 运维面数据（PRD 四角色、实际管理员数屈指可数），分页带来的复杂度无收益。</p>
     *
     * @param callerRole 调用者角色
     * @return {@link AdminAccountListResponse} 全部账号（不含口令哈希）
     * @throws BizException 非超管 → 40305
     */
    public AdminAccountListResponse list(OperatorRole callerRole) {
        requireSuper(callerRole);
        List<AdminAccountListResponse.Item> items = adminUserMapper
                .selectList(new QueryWrapper<AdminUserEntity>().orderByAsc("id"))
                .stream()
                .map(AdminAccountService::toItem)
                .toList();
        return new AdminAccountListResponse(items);
    }

    /**
     * 新建后台账号（口令哈希后入库，同事务写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param req        入参（用户名/口令/角色）
     * @throws BizException 非超管 → 40305；口令过短或角色非法 → 40001；用户名已存在 → 40001
     */
    @Transactional
    public void create(OperatorRole callerRole, Long adminId, AdminAccountCreateRequest req) {
        requireSuper(callerRole);
        OperatorRole targetRole = parseAdminRole(req.role());
        if (req.password().length() < NfrAdmin.PASSWORD_MIN_LENGTH) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        if (existsUsername(req.username())) {
            // 用户名唯一是库约束（uk_admin_username）；此处先查一次是为了给 40001 而非 50001
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        AdminUserEntity entity = new AdminUserEntity();
        entity.setUsername(req.username());
        entity.setPasswordHash(passwordHasher.hash(req.password()));
        entity.setRole(targetRole.dbValue());
        entity.setStatus(STATUS_ACTIVE);
        adminUserMapper.insert(entity);

        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_ACCOUNT_CREATE,
                TARGET_ADMIN_USER, entity.getId(), null,
                String.format("{\"username\":\"%s\",\"role\":\"%s\"}",
                        req.username(), targetRole.dbValue()), null));
    }

    /**
     * 修改后台账号的角色与状态（同事务写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param targetId   目标账号 ID
     * @param req        入参（role/status，null = 不改）
     * @throws BizException 非超管 → 40305；账号不存在 → 41001；角色/状态非法 → 40001
     */
    @Transactional
    public void update(OperatorRole callerRole, Long adminId, long targetId,
            AdminAccountUpdateRequest req) {
        requireSuper(callerRole);
        AdminUserEntity existing = adminUserMapper.selectById(targetId);
        if (existing == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        String role = null;
        if (req.role() != null) {
            role = parseAdminRole(req.role()).dbValue();
        }
        String status = null;
        if (req.status() != null) {
            if (!STATUS_ACTIVE.equals(req.status()) && !STATUS_DISABLED.equals(req.status())) {
                throw BizException.of(ErrorCode.PARAM_INVALID);
            }
            status = req.status();
        }
        if (role == null && status == null) {
            // 空更新：契约上合法但无意义，静默放过会掩盖客户端字段名拼错
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        AdminUserEntity patch = new AdminUserEntity();
        patch.setId(targetId);
        patch.setRole(role);
        patch.setStatus(status);
        adminUserMapper.updateById(patch);

        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_ACCOUNT_UPDATE,
                TARGET_ADMIN_USER, targetId,
                String.format("{\"role\":\"%s\",\"status\":\"%s\"}",
                        existing.getRole(), existing.getStatus()),
                String.format("{\"role\":%s,\"status\":%s}", jsonOrNull(role), jsonOrNull(status)),
                null));
    }

    /**
     * 重置后台账号口令（同事务写审计；审计<b>不含</b>口令任何形态）。
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param targetId   目标账号 ID
     * @param newPassword 新口令
     * @throws BizException 非超管 → 40305；账号不存在 → 41001；口令过短 → 40001
     */
    @Transactional
    public void resetPassword(OperatorRole callerRole, Long adminId, long targetId,
            String newPassword) {
        requireSuper(callerRole);
        if (newPassword == null || newPassword.length() < NfrAdmin.PASSWORD_MIN_LENGTH) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        AdminUserEntity existing = adminUserMapper.selectById(targetId);
        if (existing == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        AdminUserEntity patch = new AdminUserEntity();
        patch.setId(targetId);
        patch.setPasswordHash(passwordHasher.hash(newPassword));
        adminUserMapper.updateById(patch);

        // 审计只记「发生了重置」，不记口令值/哈希（安全红线：日志禁敏感）
        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_ACCOUNT_PASSWORD_RESET,
                TARGET_ADMIN_USER, targetId, null, null, null));
    }

    /**
     * RBAC：仅超级管理员。
     *
     * @param callerRole 调用者角色
     * @throws BizException 不满足 → 40305
     */
    private void requireSuper(OperatorRole callerRole) {
        if (callerRole != OperatorRole.SUPER_ADMIN) {
            throw BizException.of(ErrorCode.NO_PERMISSION);
        }
    }

    /**
     * 解析并可分配的后台角色（必须是 PRD §9.10.1 四角色之一）。
     *
     * @param dbValue 落库值字符串
     * @return {@link OperatorRole} 对应角色
     * @throws BizException 未知值或非后台四角色（如 system/user/admin）→ 40001
     */
    private OperatorRole parseAdminRole(String dbValue) {
        OperatorRole role = OperatorRole.fromDbValue(dbValue);
        if (role == null || !role.isAdminRole()) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return role;
    }

    /**
     * 判定用户名是否已存在。
     *
     * @param username 登录名
     * @return boolean；存在为 {@code true}
     */
    private boolean existsUsername(String username) {
        return adminUserMapper.selectCount(
                new QueryWrapper<AdminUserEntity>().eq("username", username)) > 0;
    }

    /**
     * 实体 → 出参条目（**不含 {@code password_hash}**）。
     *
     * @param entity 账号实体
     * @return {@link AdminAccountListResponse.Item} 出参
     */
    private static AdminAccountListResponse.Item toItem(AdminUserEntity entity) {
        return new AdminAccountListResponse.Item(
                entity.getId(),
                entity.getUsername(),
                entity.getRole(),
                entity.getStatus(),
                entity.getLastLoginAt() == null ? null
                        : entity.getLastLoginAt().toInstant(ZoneOffset.UTC),
                entity.getCreatedAt() == null ? null
                        : entity.getCreatedAt().toInstant(ZoneOffset.UTC));
    }

    /**
     * 字符串 → JSON 字面量（null 原样返回）。
     *
     * @param value 原始字符串
     * @return {@link String} 带引号字面量或 {@code null}
     */
    private static String jsonOrNull(String value) {
        return value == null ? null : "\"" + value + "\"";
    }
}
