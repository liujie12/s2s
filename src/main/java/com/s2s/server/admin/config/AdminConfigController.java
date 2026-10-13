package com.s2s.server.admin.config;

import com.s2s.server.admin.AdminContext;
import com.s2s.server.admin.dto.MatchConfigResponse;
import com.s2s.server.admin.dto.MatchConfigUpdateRequest;
import com.s2s.server.admin.dto.SwitchConfigResponse;
import com.s2s.server.admin.dto.SwitchConfigUpdateRequest;
import com.s2s.server.common.audit.OperatorRole;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 运营后台配置控制器（[153] B2-5）：撮合权重/AB 开关 + 降级开关。
 *
 * <p>鉴权由 {@link com.s2s.server.admin.AdminInterceptor} 承担（{@code /admin/**}）；
 * RBAC 由 {@link AdminConfigService} 判定（算法运营/超管，越权 {@code 40305}）。</p>
 */
@RestController
@RequestMapping("/admin")
public class AdminConfigController {

    /** 后台配置服务。 */
    private final AdminConfigService adminConfigService;

    /**
     * 构造后台配置控制器。
     *
     * @param adminConfigService 后台配置服务
     */
    public AdminConfigController(AdminConfigService adminConfigService) {
        this.adminConfigService = adminConfigService;
    }

    /**
     * 读取撮合权重配置（{@code GET /admin/match-config}）。
     *
     * @param http 当前请求（取后台角色）
     * @return {@link MatchConfigResponse} 权重 + GBDT 开关 + 灰度
     */
    @GetMapping("/match-config")
    public MatchConfigResponse getMatchConfig(HttpServletRequest http) {
        return adminConfigService.getMatchConfig(AdminContext.currentRole(http));
    }

    /**
     * 更新撮合权重配置（{@code PUT /admin/match-config}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param request 入参
     */
    @PutMapping("/match-config")
    public void updateMatchConfig(HttpServletRequest http,
            @Valid @RequestBody MatchConfigUpdateRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminConfigService.updateMatchConfig(role, AdminContext.currentAdminId(http), request);
    }

    /**
     * 读取降级开关（{@code GET /admin/switches}）。
     *
     * @param http 当前请求（取后台角色）
     * @return {@link SwitchConfigResponse} 模型/性能降级开关
     */
    @GetMapping("/switches")
    public SwitchConfigResponse getSwitches(HttpServletRequest http) {
        return adminConfigService.getSwitches(AdminContext.currentRole(http));
    }

    /**
     * 更新降级开关（{@code PUT /admin/switches}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param request 入参
     */
    @PutMapping("/switches")
    public void updateSwitches(HttpServletRequest http,
            @Valid @RequestBody SwitchConfigUpdateRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminConfigService.updateSwitches(role, AdminContext.currentAdminId(http), request);
    }
}
