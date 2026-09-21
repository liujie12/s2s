package com.s2s.server.auth;

import com.s2s.server.auth.dto.MyProfile;
import com.s2s.server.auth.dto.UpdateProfileRequest;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 用户资料控制器（[123] U8；详设 §5.1 {@code /users/me}）。
 *
 * <p>职责：承载 {@code GET /users/me}（查本人资料）与 {@code PATCH /users/me}
 * （改本人资料），登录态从 {@link AuthContext#currentUserId(HttpServletRequest)} 读取
 * （{@code AuthInterceptor} 已在横切链验签写入上下文）。</p>
 *
 * <p>未登录（无 Token，游客态放行至 controller）→ 40101：本人资料是登录态资源，
 * 无 userId 即拒绝（鉴权拦截器只放行游客态、不代判资源是否需要登录）。</p>
 *
 * <p>返回约定：直接返回业务 DTO（{@link MyProfile}），由 {@code ResponseBodyWrapper}
 * 套壳；输入校验经 {@code @Valid}，失败由 {@code GlobalExceptionHandler} 映射 40001。</p>
 */
@RestController
@RequestMapping("/users")
public class UserController {

    /** 用户资料服务。 */
    private final UserService userService;

    /**
     * 构造用户资料控制器。
     *
     * @param userService 用户资料服务
     */
    public UserController(UserService userService) {
        this.userService = userService;
    }

    /**
     * 获取当前用户资料（{@code GET /users/me}）。
     *
     * @param request 当前 HTTP 请求（取登录态 userId）
     * @return {@link MyProfile} 本人资料（白名单投影）
     */
    @GetMapping("/me")
    public MyProfile getMyProfile(HttpServletRequest request) {
        return userService.getMyProfile(requireUserId(request));
    }

    /**
     * 更新当前用户资料（{@code PATCH /users/me}，局部更新）。
     *
     * @param request 更新请求（nickname/avatar_media_id/default_radius，经 @Valid 校验）
     * @param http    当前 HTTP 请求（取登录态 userId）
     * @return {@link MyProfile} 更新后的本人资料
     */
    @PatchMapping("/me")
    public MyProfile updateMyProfile(@Valid @RequestBody UpdateProfileRequest request,
            HttpServletRequest http) {
        return userService.updateMyProfile(requireUserId(http), request);
    }

    /**
     * 取登录态 userId，未登录抛 40101。
     *
     * @param request 当前 HTTP 请求
     * @return {@link Long} 登录用户 ID
     * @throws BizException 未登录（无有效 Token）→ 40101
     */
    private Long requireUserId(HttpServletRequest request) {
        Long userId = AuthContext.currentUserId(request);
        if (userId == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        return userId;
    }
}
