package com.s2s.server.auth;

import com.s2s.server.auth.dto.SettingsResponse;
import com.s2s.server.auth.dto.SettingsUpdateRequest;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * 设置域控制器（[B2-11]；openapi {@code GET/PATCH /settings}）。
 *
 * <p>归 auth 域（设置=登录用户偏好，与 {@code /users/me} 同源）。强制登录态：未登录 → {@code 40101}
 * （范式同 {@link UserController#updateMyProfile}）。</p>
 */
@RestController
public class SettingController {

    private final SettingService settingService;

    /**
     * 构建设置域控制器。
     *
     * @param settingService 设置域服务
     */
    public SettingController(SettingService settingService) {
        this.settingService = settingService;
    }

    /**
     * 读取本人设置（{@code GET /settings}）。
     *
     * @param request 当前 HTTP 请求（取登录态 userId）
     * @return {@link SettingsResponse}
     * @throws BizException {@code 40101} 未登录
     */
    @GetMapping("/settings")
    public SettingsResponse getSettings(HttpServletRequest request) {
        return settingService.get(requireUserId(request));
    }

    /**
     * 修改本人设置（{@code PATCH /settings}，局部更新）。
     *
     * @param request 更新请求（notify 补丁 / default_radius）
     * @param http    当前 HTTP 请求（取登录态 userId）
     * @return {@link SettingsResponse} 更新后的完整设置
     * @throws BizException {@code 40101} 未登录；{@code 40001} default_radius 非法
     */
    @PatchMapping("/settings")
    public SettingsResponse updateSettings(@RequestBody SettingsUpdateRequest request,
            HttpServletRequest http) {
        return settingService.update(requireUserId(http), request);
    }

    /**
     * 取登录态 userId，未登录抛 {@code 40101}。
     *
     * @param request 当前 HTTP 请求
     * @return {@link Long} 登录用户 ID
     * @throws BizException {@code 40101}
     */
    private Long requireUserId(HttpServletRequest request) {
        Long userId = AuthContext.currentUserId(request);
        if (userId == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        return userId;
    }
}
