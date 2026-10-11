package com.s2s.server.cert;

import com.s2s.server.cert.dto.CertStatusResponse;
import com.s2s.server.cert.dto.QualificationSubmitRequest;
import com.s2s.server.cert.dto.QualificationSubmitResult;
import com.s2s.server.cert.dto.RealnameSubmitRequest;
import com.s2s.server.cert.dto.RealnameSubmitResult;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 认证控制器（[149]；详设 §5.7，openapi 分组七「认证」三端点）。
 *
 * <p>职责：承载 {@code POST /cert/realname}（提交实名）、{@code POST /cert/qualification}
 * （提交资质）、{@code GET /cert/status}（查询认证状态），登录态从
 * {@link AuthContext#currentUserId(HttpServletRequest)} 读取。</p>
 *
 * <p>返回约定：直接返回业务 DTO，由 {@code ResponseBodyWrapper} 套壳；输入校验经
 * {@code @Valid}，失败由 {@code GlobalExceptionHandler} 映射 40001。</p>
 */
@RestController
@RequestMapping("/cert")
public class CertController {

    /** 认证服务。 */
    private final CertService certService;

    /**
     * 构造认证控制器。
     *
     * @param certService 认证服务
     */
    public CertController(CertService certService) {
        this.certService = certService;
    }

    /**
     * 提交实名认证（{@code POST /cert/realname}）。
     *
     * @param request 实名提交请求（real_name/id_card/agreement_accepted，经 @Valid 校验）
     * @param http    当前 HTTP 请求（取登录态 userId）
     * @return {@link RealnameSubmitResult} 实名状态
     */
    @PostMapping("/realname")
    public RealnameSubmitResult submitRealname(@Valid @RequestBody RealnameSubmitRequest request,
            HttpServletRequest http) {
        return certService.submitRealname(requireUserId(http), request);
    }

    /**
     * 提交资质认证（{@code POST /cert/qualification}）。
     *
     * @param request 资质提交请求（cert_type/media_ids，经 @Valid 校验）
     * @param http    当前 HTTP 请求（取登录态 userId）
     * @return {@link QualificationSubmitResult} 提交后状态 + 审核 SLA
     */
    @PostMapping("/qualification")
    public QualificationSubmitResult submitQualification(
            @Valid @RequestBody QualificationSubmitRequest request, HttpServletRequest http) {
        return certService.submitQualification(requireUserId(http), request);
    }

    /**
     * 查询认证状态（{@code GET /cert/status}）。
     *
     * @param http 当前 HTTP 请求（取登录态 userId）
     * @return {@link CertStatusResponse} 实名状态 + 资质列表
     */
    @GetMapping("/status")
    public CertStatusResponse getCertStatus(HttpServletRequest http) {
        return certService.getCertStatus(requireUserId(http));
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
