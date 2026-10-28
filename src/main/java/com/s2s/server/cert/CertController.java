package com.s2s.server.cert;

import com.s2s.server.cert.dto.CertOcrRequest;
import com.s2s.server.cert.dto.CertOcrResult;
import com.s2s.server.cert.dto.CertStatusResponse;
import com.s2s.server.cert.dto.QualificationSubmitRequest;
import com.s2s.server.cert.dto.QualificationSubmitResult;
import com.s2s.server.cert.dto.QualificationUpdateRequest;
import com.s2s.server.cert.dto.RealnameSubmitRequest;
import com.s2s.server.cert.dto.RealnameSubmitResult;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 认证控制器（[149]；详设 §5.7，openapi 分组七「认证」端点）。
 *
 * <p>职责：承载 {@code POST /cert/realname}（提交实名）、{@code POST /cert/qualification}
 * （新增资质）、{@code PATCH/DELETE /cert/qualification/{cert_id}}（编辑/删除）、
 * {@code POST /cert/ocr}（证照图抽取）、{@code GET /cert/status}（查询认证状态），
 * 登录态从 {@link AuthContext#currentUserId(HttpServletRequest)} 读取。</p>
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
     * 新增资质（{@code POST /cert/qualification}）。
     *
     * @param request 资质提交请求（类型/证照图/证名/有效期，经 @Valid 校验）
     * @param http    当前 HTTP 请求（取登录态 userId）
     * @return {@link QualificationSubmitResult} 新记录 ID + 生效状态
     */
    @PostMapping("/qualification")
    public QualificationSubmitResult submitQualification(
            @Valid @RequestBody QualificationSubmitRequest request, HttpServletRequest http) {
        return certService.submitQualification(requireUserId(http), request);
    }

    /**
     * 编辑资质（{@code PATCH /cert/qualification/{cert_id}}）。
     *
     * @param certId  资质 ID
     * @param request 编辑载荷（字段全部可选）
     * @param http    当前 HTTP 请求（取登录态 userId）
     * @return {@link QualificationSubmitResult} 记录 ID + 重算后的状态
     */
    @PatchMapping("/qualification/{cert_id}")
    public QualificationSubmitResult updateQualification(@PathVariable("cert_id") long certId,
            @Valid @RequestBody QualificationUpdateRequest request, HttpServletRequest http) {
        return certService.updateQualification(requireUserId(http), certId, request);
    }

    /**
     * 删除资质（{@code DELETE /cert/qualification/{cert_id}}）。
     *
     * @param certId 资质 ID
     * @param http   当前 HTTP 请求（取登录态 userId）
     * @return {@link Void} 由统一响应包套壳（data 为 null）
     */
    @DeleteMapping("/qualification/{cert_id}")
    public Void deleteQualification(@PathVariable("cert_id") long certId,
            HttpServletRequest http) {
        certService.deleteQualification(requireUserId(http), certId);
        return null;
    }

    /**
     * 从证照图抽取证名与有效期（{@code POST /cert/ocr}）。
     *
     * @param request 抽取请求（media_id，经 @Valid 校验）
     * @param http    当前 HTTP 请求（取登录态 userId）
     * @return {@link CertOcrResult} 证名与有效期（均可空）
     */
    @PostMapping("/ocr")
    public CertOcrResult extractCertProfile(@Valid @RequestBody CertOcrRequest request,
            HttpServletRequest http) {
        return certService.extractCertProfile(requireUserId(http), request.mediaId());
    }

    /**
     * 查询认证状态与资质档案（{@code GET /cert/status}）。
     *
     * @param http 当前 HTTP 请求（取登录态 userId）
     * @return {@link CertStatusResponse} 实名状态 + 资质档案
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
