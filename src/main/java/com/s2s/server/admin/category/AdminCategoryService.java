package com.s2s.server.admin.category;

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
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 后台分类配置服务（[153] B2-5 ①；PRD §9.10.1 ①）。
 *
 * <p><b>RBAC</b>：分类配置属「运营专员」职责（PRD §9.10.1 角色表）——运营专员与
 * 超级管理员可操作，其余角色一律 {@code 40305}。</p>
 *
 * <p><b>审计</b>：新增/修改类目属「必留操作」，写库与审计<b>同事务</b>。
 * 「改完客户端 5 分钟内生效」的落地口径见 {@link CategoryService}：bump 分类树版本号
 * + 失效本地缓存，客户端按版本协商（openapi {@code /categories/tree}）拉到新树。</p>
 *
 * <p><b>域边界</b>：{@code category} 表由 category 域的 {@link CategoryService}
 * 提供数据操作（admin 不直连本域 Mapper，编码规范 §4.2）。</p>
 */
@Service
public class AdminCategoryService {

    /** 审计动作：新增类目。 */
    static final String ACTION_CATEGORY_CREATE = "category.create";

    /** 审计动作：修改类目。 */
    static final String ACTION_CATEGORY_UPDATE = "category.update";

    /** 审计目标类型：分类。 */
    static final String TARGET_CATEGORY = "category";

    /** 分类服务（category 域 service 接口）。 */
    private final CategoryService categoryService;

    /** 审计写入器（唯一写入处）。 */
    private final AuditLogWriter auditLogWriter;

    /**
     * 构造后台分类配置服务。
     *
     * @param categoryService category 域服务
     * @param auditLogWriter  审计写入器
     */
    public AdminCategoryService(CategoryService categoryService, AuditLogWriter auditLogWriter) {
        this.categoryService = categoryService;
        this.auditLogWriter = auditLogWriter;
    }

    /**
     * 列出全量分类（后台配置页）。
     *
     * @param callerRole 调用者角色
     * @return {@link AdminCategoryListResponse} 全量分类行
     * @throws BizException 非运营专员/超管 → 40305
     */
    public AdminCategoryListResponse list(OperatorRole callerRole) {
        requireOperatorOrSuper(callerRole);
        List<AdminCategoryListResponse.Item> items = categoryService.listAllForAdmin().stream()
                .map(AdminCategoryService::toItem)
                .toList();
        return new AdminCategoryListResponse(items);
    }

    /**
     * 新增叶子类目（同事务写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param req        入参
     * @throws BizException 非运营专员/超管 → 40305；父级非法 → 40001
     */
    @Transactional
    public void create(OperatorRole callerRole, Long adminId, AdminCategoryCreateRequest req) {
        requireOperatorOrSuper(callerRole);
        Integer newId = categoryService.createLeaf(req.parentId(), req.name(), req.icon(),
                req.needCert(), req.forbidden(), req.sortOrder());
        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_CATEGORY_CREATE,
                TARGET_CATEGORY, newId.longValue(), null,
                String.format("{\"parentId\":%d,\"name\":\"%s\"}", req.parentId(), req.name()), null));
    }

    /**
     * 更新类目可配字段（同事务写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param categoryId 类目 ID
     * @param req        入参（null 字段 = 不改）
     * @throws BizException 非运营专员/超管 → 40305；类目不存在 → 41001
     */
    @Transactional
    public void update(OperatorRole callerRole, Long adminId, int categoryId,
            AdminCategoryUpdateRequest req) {
        requireOperatorOrSuper(callerRole);
        categoryService.updateCategory(categoryId, req.name(), req.icon(), req.needCert(),
                req.forbidden(), req.sortOrder());
        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_CATEGORY_UPDATE,
                TARGET_CATEGORY, (long) categoryId, null,
                String.format("{\"name\":%s,\"forbidden\":%s}", jsonOrNull(req.name()),
                        req.forbidden()), null));
    }

    /**
     * RBAC：运营专员或超级管理员。
     *
     * @param callerRole 调用者角色
     * @throws BizException 不满足 → 40305
     */
    private void requireOperatorOrSuper(OperatorRole callerRole) {
        if (callerRole != OperatorRole.OPERATOR && callerRole != OperatorRole.SUPER_ADMIN) {
            throw BizException.of(ErrorCode.NO_PERMISSION);
        }
    }

    /**
     * 域实体 → 出参条目。
     *
     * @param entity 分类实体
     * @return {@link AdminCategoryListResponse.Item} 出参
     */
    private static AdminCategoryListResponse.Item toItem(CategoryEntity entity) {
        return new AdminCategoryListResponse.Item(
                entity.getId(),
                entity.getParentId(),
                entity.getLevel(),
                entity.getName(),
                entity.getIcon(),
                entity.getNeedCert(),
                entity.getForbidden(),
                entity.getSortOrder(),
                entity.getClusterThreshold());
    }

    /**
     * 字符串 → JSON 字面量（null 原样返回，避免审计出现裸 {@code null} 文本）。
     *
     * @param value 原始字符串
     * @return {@link String} 带引号的 JSON 字面量或 {@code null}
     */
    private static String jsonOrNull(String value) {
        return value == null ? null : "\"" + value + "\"";
    }
}
