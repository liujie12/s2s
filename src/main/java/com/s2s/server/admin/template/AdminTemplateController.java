package com.s2s.server.admin.template;

import com.s2s.server.admin.AdminContext;
import com.s2s.server.admin.dto.AdminTemplateResponse;
import com.s2s.server.admin.dto.AdminTemplateSaveRequest;
import com.s2s.server.common.audit.OperatorRole;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 后台模板 Schema 控制器（[153] B2-5 ②）。
 *
 * <p>鉴权由 {@link com.s2s.server.admin.AdminInterceptor} 承担；RBAC 由
 * {@link AdminTemplateService} 判定（运营专员/超管，越权 {@code 40305}）。</p>
 */
@RestController
@RequestMapping("/admin/templates")
public class AdminTemplateController {

    /** 后台模板服务。 */
    private final AdminTemplateService adminTemplateService;

    /**
     * 构造后台模板控制器。
     *
     * @param adminTemplateService 后台模板服务
     */
    public AdminTemplateController(AdminTemplateService adminTemplateService) {
        this.adminTemplateService = adminTemplateService;
    }

    /**
     * 读取模板（{@code GET /admin/templates/{template_key}}）。
     *
     * @param http        当前请求（取后台角色）
     * @param templateKey 模板键（L2 类目 ID）
     * @return {@link AdminTemplateResponse} 版本号 + Schema
     */
    @GetMapping("/{template_key}")
    public AdminTemplateResponse get(HttpServletRequest http,
            @PathVariable("template_key") int templateKey) {
        return adminTemplateService.get(AdminContext.currentRole(http), templateKey);
    }

    /**
     * 保存模板新版本（{@code PUT /admin/templates/{template_key}}）。
     *
     * @param http        当前请求（取后台角色/操作人）
     * @param templateKey 模板键（L2 类目 ID）
     * @param request     入参（fields 数组）
     */
    @PutMapping("/{template_key}")
    public void save(HttpServletRequest http, @PathVariable("template_key") int templateKey,
            @Valid @RequestBody AdminTemplateSaveRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminTemplateService.save(role, AdminContext.currentAdminId(http), templateKey, request);
    }
}
