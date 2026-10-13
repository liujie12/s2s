package com.s2s.server.admin.tempcategory;

import com.s2s.server.admin.AdminContext;
import com.s2s.server.admin.dto.AdminTempCategoryCreateRequest;
import com.s2s.server.admin.dto.AdminTempCategoryListResponse;
import com.s2s.server.common.audit.OperatorRole;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 后台临时类目控制器（[153] B2-5 §9.10.2；PRD §9.10.2）。
 *
 * <p>鉴权由 {@link com.s2s.server.admin.AdminInterceptor} 承担；RBAC 由
 * {@link AdminTempCategoryService} 判定（运营专员/超管，越权 {@code 40305}）。</p>
 */
@RestController
@RequestMapping("/admin/temp-categories")
public class AdminTempCategoryController {

    /** 后台临时类目服务。 */
    private final AdminTempCategoryService adminTempCategoryService;

    /**
     * 构造后台临时类目控制器。
     *
     * @param adminTempCategoryService 后台临时类目服务
     */
    public AdminTempCategoryController(AdminTempCategoryService adminTempCategoryService) {
        this.adminTempCategoryService = adminTempCategoryService;
    }

    /**
     * 临时类目列表（{@code GET /admin/temp-categories}）。
     *
     * @param http     当前请求（取后台角色）
     * @param status   生命周期筛选（可选，默认不限）
     * @param page     页码（可选）
     * @param pageSize 每页条数（可选）
     * @return {@link AdminTempCategoryListResponse} 列表分页
     */
    @GetMapping
    public AdminTempCategoryListResponse list(HttpServletRequest http,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) Integer page,
            @RequestParam(name = "page_size", required = false) Integer pageSize) {
        return adminTempCategoryService.list(AdminContext.currentRole(http), status, page, pageSize);
    }

    /**
     * 创建临时类目（{@code POST /admin/temp-categories}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param request 入参
     */
    @PostMapping
    public void create(HttpServletRequest http,
            @Valid @RequestBody AdminTempCategoryCreateRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminTempCategoryService.create(role, AdminContext.currentAdminId(http), request);
    }
}
