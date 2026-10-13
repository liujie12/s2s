package com.s2s.server.admin.tempcategory;

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
import java.time.ZoneOffset;
import java.util.List;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 后台临时类目服务（[153] B2-5 §9.10.2；PRD §9.10.2）。
 *
 * <p><b>RBAC</b>：临时类目属「运营专员」职责（PRD §9.10.1 角色表「运营专员…临时类目」）
 * ——运营专员与超级管理员可操作，其余角色一律 {@code 40305}。</p>
 *
 * <p><b>审计</b>：创建临时类目属「必留操作」（分类变更），写库与审计<b>同事务</b>。</p>
 *
 * <p><b>域边界</b>：临时类目由 {@code ops} 域承载，后台经 {@link TempCategoryService}
 * 取数与创建（admin 不直连他域 Mapper，编码规范 §4.2）。</p>
 */
@Service
public class AdminTempCategoryService {

    /** 审计动作：创建临时类目。 */
    static final String ACTION_TEMP_CATEGORY_CREATE = "temp_category.create";

    /** 审计目标类型：临时类目。 */
    static final String TARGET_TEMP_CATEGORY = "temp_category";

    /** ops 域临时类目服务。 */
    private final TempCategoryService tempCategoryService;

    /** 审计写入器（唯一写入处）。 */
    private final AuditLogWriter auditLogWriter;

    /**
     * 构造后台临时类目服务。
     *
     * @param tempCategoryService ops 域临时类目服务
     * @param auditLogWriter      审计写入器
     */
    public AdminTempCategoryService(TempCategoryService tempCategoryService,
            AuditLogWriter auditLogWriter) {
        this.tempCategoryService = tempCategoryService;
        this.auditLogWriter = auditLogWriter;
    }

    /**
     * 分页列出临时类目。
     *
     * @param callerRole 调用者角色
     * @param status     生命周期筛选（null/空 → 不限）
     * @param page       页码（null/小于 1 → 1）
     * @param pageSize   每页条数（null → 默认；超上限截断）
     * @return {@link AdminTempCategoryListResponse} 列表分页
     * @throws BizException 非运营专员/超管 → 40305
     */
    public AdminTempCategoryListResponse list(OperatorRole callerRole, String status, Integer page,
            Integer pageSize) {
        requireOperatorOrSuper(callerRole);
        int normalizedPage = (page == null || page < 1) ? 1 : page;
        int normalizedSize = pageSize == null || pageSize < 1
                ? NfrAdmin.PAGE_SIZE_DEFAULT
                : Math.min(pageSize, NfrAdmin.PAGE_SIZE_MAX);

        TempCategoryPage domainPage =
                tempCategoryService.list(status, normalizedPage, normalizedSize);
        List<AdminTempCategoryListResponse.Item> items = domainPage.items().stream()
                .map(AdminTempCategoryService::toItem)
                .toList();
        return new AdminTempCategoryListResponse(items, domainPage.total(), normalizedPage,
                normalizedSize);
    }

    /**
     * 创建临时类目（同事务写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param req        入参
     * @throws BizException 非运营专员/超管 → 40305；父级非法 → 40001
     */
    @Transactional
    public void create(OperatorRole callerRole, Long adminId, AdminTempCategoryCreateRequest req) {
        requireOperatorOrSuper(callerRole);
        Integer leafId = tempCategoryService.createTempLeaf(req.l2ParentId(), req.name(), adminId);
        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_TEMP_CATEGORY_CREATE,
                TARGET_TEMP_CATEGORY, leafId.longValue(), null,
                String.format("{\"l2ParentId\":%d,\"name\":\"%s\"}", req.l2ParentId(), req.name()),
                null));
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
     * 域视图 → 出参条目。
     *
     * @param view 临时类目视图
     * @return {@link AdminTempCategoryListResponse.Item} 出参
     */
    private static AdminTempCategoryListResponse.Item toItem(TempCategoryView view) {
        return new AdminTempCategoryListResponse.Item(
                view.id(),
                view.l2ParentId(),
                view.name(),
                view.status(),
                view.createdBy(),
                toInstant(view.createdAt()),
                toInstant(view.expireAt()),
                toInstant(view.closedAt()),
                view.publishCount(),
                view.contactCount(),
                view.promoted() == null ? null : view.promoted() == 1);
    }

    /**
     * 库内 {@link LocalDateTime} → 对外 {@link java.time.Instant}（null 透传）。
     *
     * @param value 库内时间
     * @return {@link java.time.Instant} 以 UTC 解释的时间；{@code null} 原样返回
     */
    private static java.time.Instant toInstant(LocalDateTime value) {
        return value == null ? null : value.toInstant(ZoneOffset.UTC);
    }
}
