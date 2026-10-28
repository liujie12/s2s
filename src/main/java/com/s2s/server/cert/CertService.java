package com.s2s.server.cert;

import com.s2s.server.ai.AiProvider;
import com.s2s.server.ai.dto.CertProfileGuess;
import com.s2s.server.auth.UserService;
import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.baomidou.mybatisplus.core.conditions.update.UpdateWrapper;
import com.s2s.server.cert.dto.CertOcrResult;
import com.s2s.server.cert.dto.CertReviewPage;
import com.s2s.server.cert.dto.CertSnapshot;
import com.s2s.server.cert.dto.CertStatusResponse;
import com.s2s.server.cert.dto.QualificationItem;
import com.s2s.server.cert.dto.QualificationSubmitRequest;
import com.s2s.server.cert.dto.QualificationSubmitResult;
import com.s2s.server.cert.dto.QualificationUpdateRequest;
import com.s2s.server.cert.dto.RealnameSubmitRequest;
import com.s2s.server.cert.dto.RealnameSubmitResult;
import com.s2s.server.cert.entity.CertEntity;
import com.s2s.server.cert.mapper.CertMapper;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.crypto.BlindIndex;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.crypto.Pepper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.post.MediaService;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 认证服务（[149]；由 Batch1 空壳转真，详设 §5.7）。
 *
 * <p>职责：承载 cert 域接口——{@code POST /cert/realname}（二要素核验 →
 * {@code user.realname_status} 落库）、{@code GET /cert/status}（实名状态 + 资质档案）、
 * {@code POST /cert/qualification}（新增资质，提交即 {@code approved}）、
 * {@code PATCH/DELETE /cert/qualification/{id}}（编辑/删除）、
 * {@code POST /cert/ocr}（证照图抽取证名）。同时保留
 * {@link #getRealnameStatus} 供 post 域查询实名状态（详设 §1.3 域间只调 service）。</p>
 *
 * <p><b>域边界</b>：读写 {@code user} 表实名列经 {@link UserService}（auth 域 service）、
 * 证照图归属校验与签名经 {@link MediaService}（post 域 service）、模型抽取经
 * {@link AiProvider}（ai 域接口）；本类不注入其他域 mapper（编码规范 §4.2）。
 * {@code cert} 表经本域 {@link CertMapper}。</p>
 *
 * <p><b>审核口径（2026-10-28 裁定）</b>：取消人工审核，提交即 {@code approved}；
 * {@code pending}/{@code rejected} 保留在枚举里，本轮不写入。资质同时取消「证件类型 + 有效期」，
 * 只保留「证书名 + 证照图」：{@code expired} 状态与每日过期任务一并移除（V23）。</p>
 *
 * <p><b>手机号一致性（DEC-30 ③）</b>：复用已登录手机号这一事实（短信验证码登录即证明
 * 手机号归本人），<b>不向供应商传手机号、不解密 {@code user_identity}</b>，故本类不调
 * {@code CryptoFacade.decrypt}（解密调用点计数保持 ==1，DoD D2 基线不漂移）。</p>
 *
 * <p><b>安全红线</b>：{@code real_name}/{@code id_card} 明文仅用于核验与加密/盲索引，
 * 不写日志（编码规范 §4.11）；敏感列永不出现在任何 API 响应。</p>
 */
@Service
public class CertService {

    /** 实名状态枚举值：未实名（{@code user.realname_status='none'}，注册默认值）。 */
    public static final String REALNAME_STATUS_NONE = "none";

    /** 实名状态枚举值：已通过（二要素核验通过后写回）。 */
    public static final String REALNAME_STATUS_PASSED = "passed";

    /** 认证类型：个人实名（{@code cert.cert_type} 列，实名核验专用；供 {@link CertFailureRecorder} 复用）。 */
    public static final String CERT_TYPE_PERSONAL_REALNAME = "personal_realname";

    /** 认证类型：企业认证（举报风险分的举报方权重据此判定 ×1.5，PRD §9.10.3）。 */
    public static final String CERT_TYPE_ENTERPRISE = "enterprise";

    /** 认证类型：个人资质（资质提交内部固定写该值；不出现在任何请求/响应）。 */
    public static final String CERT_TYPE_QUALIFICATION = "personal_qualification";

    /** 认证状态：审核中（历史枚举值；本轮不写入，仅供 {@link CertFailureRecorder} 复用）。 */
    public static final String CERT_STATUS_PENDING = "pending";

    /** 认证状态：已通过（实名核验通过 / 资质提交即生效）。 */
    private static final String CERT_STATUS_APPROVED = "approved";

    /** 证书名最大长度（与契约 {@code maxLength: 64} 对齐）。 */
    private static final int CERT_NAME_MAX_LENGTH = 64;

    /** 证名来源：自动读取（用户未改动抽取结果）。 */
    private static final String NAME_SOURCE_OCR = "ocr";

    /** 证名来源：手工填写（用户手填或改写）。 */
    private static final String NAME_SOURCE_MANUAL = "manual";

    /** 审计动作：提交实名认证。 */
    private static final String AUDIT_ACTION_REALNAME_SUBMIT = "realname.submit";

    /** 审计动作：提交资质认证。 */
    private static final String AUDIT_ACTION_QUALIFICATION_SUBMIT = "qualification.submit";

    /** 审计动作：编辑资质。 */
    private static final String AUDIT_ACTION_QUALIFICATION_UPDATE = "qualification.update";

    /** 审计动作：删除资质。 */
    private static final String AUDIT_ACTION_QUALIFICATION_DELETE = "qualification.delete";

    /** 审计目标对象类型：用户。 */
    private static final String AUDIT_TARGET_USER = "user";

    /** 用户资料服务（读/写 user 实名列，域间只调 service）。 */
    private final UserService userService;

    /** cert 表 Mapper（本域自有）。 */
    private final CertMapper certMapper;

    /** 实名核验供应商（dry-run mock）。 */
    private final RealnameProvider realnameProvider;

    /** 全系统唯一加解密入口（加密姓名，不解密）。 */
    private final CryptoFacade cryptoFacade;

    /** HMAC pepper 列表（身份证盲索引）。 */
    private final List<Pepper> peppers;

    /** 全系统唯一 audit_log 写入处。 */
    private final AuditLogWriter auditLogWriter;

    /** 核验失败计数与锁定记录器（独立事务，评审 P0 修复）。 */
    private final CertFailureRecorder certFailureRecorder;

    /** 媒体服务（证照图归属校验、签名地址、OSS 原件清理）。 */
    private final MediaService mediaService;

    /** 大模型供应商（证照图抽取证名）。 */
    private final AiProvider aiProvider;

    /**
     * 构造认证服务。
     *
     * @param userService          用户资料服务（读/写 user 实名列）
     * @param certMapper           cert 表 Mapper
     * @param realnameProvider     实名核验供应商
     * @param cryptoFacade         加解密入口（加密姓名）
     * @param peppers              HMAC pepper 列表（身份证盲索引）
     * @param auditLogWriter       审计写入
     * @param certFailureRecorder  核验失败计数与锁定记录器
     * @param mediaService         媒体服务（证照图归属校验与签名）
     * @param aiProvider           大模型供应商（证照图抽取）
     */
    public CertService(UserService userService, CertMapper certMapper,
            RealnameProvider realnameProvider, CryptoFacade cryptoFacade,
            List<Pepper> peppers, AuditLogWriter auditLogWriter,
            CertFailureRecorder certFailureRecorder, MediaService mediaService,
            AiProvider aiProvider) {
        this.userService = userService;
        this.certMapper = certMapper;
        this.realnameProvider = realnameProvider;
        this.cryptoFacade = cryptoFacade;
        this.peppers = peppers;
        this.auditLogWriter = auditLogWriter;
        this.certFailureRecorder = certFailureRecorder;
        this.mediaService = mediaService;
        this.aiProvider = aiProvider;
    }

    /**
     * 查询用户实名状态（读 {@code user.realname_status}，供 post 域与本人查询）。
     *
     * @param userId 用户 ID
     * @return {@link String} 实名状态（{@code none/pending/passed/rejected}）；
     *         用户不存在时返回 {@value #REALNAME_STATUS_NONE}
     */
    public String getRealnameStatus(Long userId) {
        String status = userService.realnameStatusOf(userId);
        return status == null ? REALNAME_STATUS_NONE : status;
    }

    /**
     * 判断用户是否已实名通过（[153] B2-5 ④：举报方门槛「仅已实名用户可提交举报」，
     * PRD §9.10.3）。
     *
     * @param userId 用户 ID
     * @return boolean；{@code user.realname_status='passed'} 时为 {@code true}
     */
    public boolean isRealnamePassed(Long userId) {
        return REALNAME_STATUS_PASSED.equals(getRealnameStatus(userId));
    }

    /**
     * 判断用户是否已通过企业认证（[153] B2-5 ④：举报方权重 ×1.5 的判定依据，
     * PRD §9.10.3「举报方权重：普通实名 ×1，企业认证 ×1.5」）。
     *
     * @param userId 用户 ID
     * @return boolean；{@code cert} 表存在 {@code cert_type=enterprise} 且
     *         {@code status=approved} 的行时为 {@code true}
     */
    public boolean isEnterpriseVerified(Long userId) {
        return certMapper.selectCount(new QueryWrapper<CertEntity>()
                .eq("user_id", userId)
                .eq("cert_type", CERT_TYPE_ENTERPRISE)
                .eq("status", CERT_STATUS_APPROVED)) > 0;
    }

    /**
     * 提交实名认证（二要素核验；{@code POST /cert/realname}）。
     *
     * <p>执行次序：协议校验（40002）→ 已实名幂等短路 → 锁定检查（40001）→ 二要素核验
     * （失败 40001 + 记 fail_count，独立事务见 {@link CertFailureRecorder}）→ 通过后写
     * user 实名列（经 UserService）+ 写 cert 表 + 写审计（同事务）。</p>
     *
     * <p><b>锁定恢复路径（口径待裁定）</b>：PRD §4.8「需人工申诉」与本实现的
     * {@code lock_until} 自然过期恢复存在冲突；人工申诉依赖 B2-5 运营后台（当前未上线），
     * 故本阶段先取自然过期恢复，{@code fail_count} 锁过期后重新计数。</p>
     *
     * @param userId  当前登录用户 ID（controller 已保证非 null）
     * @param request 实名提交请求（real_name/id_card/agreement_accepted）
     * @return {@link RealnameSubmitResult} 实名状态（通过后为 {@code passed}）
     * @throws BizException {@code 40002} 协议未勾选 / {@code 40001} 锁定或核验不通过 /
     *         {@code 50302} 认证服务不可用
     */
    @Transactional
    public RealnameSubmitResult submitRealname(Long userId, RealnameSubmitRequest request) {
        if (!Boolean.TRUE.equals(request.agreementAccepted())) {
            throw BizException.of(ErrorCode.AGREEMENT_REQUIRED);
        }
        String current = getRealnameStatus(userId);
        if (REALNAME_STATUS_PASSED.equals(current)) {
            // 已实名：幂等返回，不重复调供应商（DEC-30 ⑦「返回业务结果即计费一次」）
            return new RealnameSubmitResult(current);
        }
        if (certFailureRecorder.isLocked(userId)) {
            // 锁定期内不再调供应商，避免锁定期间继续计费（DEC-30 ⑦）
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        // 注：真联调后 verify 为外部 HTTP，须移出 @Transactional（避免持事务跨网络）；
        // dry-run mock 为纯内存判断，无网络无感（评审 P2-4，真 API 接入时处理）
        boolean passed;
        try {
            passed = realnameProvider.verify(request.realName(), request.idCard());
        } catch (IllegalStateException exception) {
            // 供应商不可用（含 dry-run 关闭但真 API 未接入）→ 50302
            throw BizException.of(ErrorCode.CERT_UNAVAILABLE);
        }
        if (!passed) {
            // 失败计数走独立事务（REQUIRES_NEW），业务异常回滚前已持久化（评审 P0）
            certFailureRecorder.recordFailure(userId);
            // 核验不通过与锁定态同码 40001（不新增错误码，红线）
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        // AAD = user_id（详设 §4.2 表：user.real_name_enc → user_id）
        CryptoFacade.EncryptResult encrypted = cryptoFacade.encrypt(request.realName(),
                String.valueOf(userId));
        byte[] idCardHash = BlindIndex.hmac(request.idCard(), peppers);
        String idCardLast4 = request.idCard().substring(request.idCard().length() - 4);

        userService.applyRealnameResult(userId, REALNAME_STATUS_PASSED, encrypted.ciphertext(),
                idCardHash, idCardLast4, encrypted.keyVersion());
        writeCertApproved(userId);
        // 用户触发留痕 operator_role 取 user（DEC-11 / [147]）
        auditLogWriter.write(AuditEntry.minimal(userId, OperatorRole.USER,
                AUDIT_ACTION_REALNAME_SUBMIT, AUDIT_TARGET_USER, userId));
        return new RealnameSubmitResult(REALNAME_STATUS_PASSED);
    }

    /**
     * 查询认证状态与资质档案（{@code GET /cert/status}）。
     *
     * @param userId 当前登录用户 ID
     * @return {@link CertStatusResponse} 实名状态 + 本人全部资质（个人实名不算资质，不下发）
     */
    public CertStatusResponse getCertStatus(Long userId) {
        List<CertEntity> rows = certMapper.selectList(new QueryWrapper<CertEntity>()
                .eq("user_id", userId)
                .ne("cert_type", CERT_TYPE_PERSONAL_REALNAME)
                .eq("status", CERT_STATUS_APPROVED)
                .orderByDesc("submitted_at"));
        List<QualificationItem> items = new ArrayList<>(rows.size());
        for (CertEntity row : rows) {
            items.add(toItem(userId, row));
        }
        return new CertStatusResponse(
                new CertStatusResponse.RealnameStatus(getRealnameStatus(userId)), items);
    }

    /**
     * 提交资质认证（{@code POST /cert/qualification}）。
     *
     * <p>本轮取消人工审核：落库即 {@code approved}。资质只收「证照图 + 证书名」，
     * 证件类型内部固定为 {@link #CERT_TYPE_QUALIFICATION}；未实名用户提交资质回
     * {@code 40302}（高敏类目前置实名）。</p>
     *
     * @param userId  当前登录用户 ID
     * @param request 资质提交请求（证照图/证名/证名来源）
     * @return {@link QualificationSubmitResult} 新记录 ID + 生效状态（恒 {@code approved}）
     * @throws BizException {@code 40302} 未实名 / {@code 40001} 参数非法或媒体非本人
     */
    @Transactional
    public QualificationSubmitResult submitQualification(Long userId,
            QualificationSubmitRequest request) {
        if (!REALNAME_STATUS_PASSED.equals(getRealnameStatus(userId))) {
            throw BizException.of(ErrorCode.QUALIFICATION_NEEDED);
        }
        if (request.mediaIds() == null || request.mediaIds().isEmpty()) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        String imageRef = request.mediaIds().get(0);
        if (imageRef == null || imageRef.isBlank()) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        String certName = requireCertName(request.certName());
        String nameSource = requireNameSource(request.nameSource());
        mediaService.ensureOwned(userId, imageRef);

        LocalDateTime now = LocalDateTime.now();
        CertEntity entity = new CertEntity();
        entity.setUserId(userId);
        entity.setCertType(CERT_TYPE_QUALIFICATION);
        entity.setCertName(certName);
        entity.setNameSource(nameSource);
        entity.setStatus(CERT_STATUS_APPROVED);
        entity.setSubmittedAt(now);
        entity.setApprovedAt(now);
        entity.setOcrImageRef(imageRef);
        certMapper.insert(entity);
        auditLogWriter.write(AuditEntry.minimal(userId, OperatorRole.USER,
                AUDIT_ACTION_QUALIFICATION_SUBMIT, AUDIT_TARGET_USER, userId));
        return new QualificationSubmitResult(entity.getId(), CERT_STATUS_APPROVED);
    }

    /**
     * 从证照图抽取证名（{@code POST /cert/ocr}）。
     *
     * <p>抽取失败不是错误：返回 {@code certName} 为 {@code null} 的结果，由客户端提示手填。
     * 只有媒体非本人（40001）与上游不可用（50301）才抛业务异常。</p>
     *
     * @param userId  当前登录用户 ID
     * @param mediaId 已 commit 的证照图 media_id
     * @return {@link CertOcrResult} 证名（可空）
     * @throws BizException 媒体不存在/非本人 → 40001；上游不可用 → 50301
     */
    public CertOcrResult extractCertProfile(Long userId, String mediaId) {
        MediaService.AiMediaAccess access = mediaService.signAiReadAccess(userId, mediaId);
        try {
            CertProfileGuess guess = aiProvider.extractCertProfile(userId, access.accessUrl(),
                    access.contentType());
            return new CertOcrResult(guess.certName());
        } catch (RuntimeException e) {
            // 不打印 URL（含签名）与图片内容；仅映射错误码
            throw BizException.of(ErrorCode.AI_UNAVAILABLE);
        }
    }

    /**
     * 编辑资质（{@code PATCH /cert/qualification/{cert_id}}）。
     *
     * <p>只改传入项：换图只替换证照图引用、不重复抽取；改名只改证名。资质无有效期概念，
     * 编辑不涉及状态流转。已生成的帖级快照不回溯。</p>
     *
     * @param userId  当前登录用户 ID
     * @param certId  资质 ID
     * @param request 编辑载荷（字段全部可选，至少一项）
     * @return {@link QualificationSubmitResult} 记录 ID + 当前状态（恒 {@code approved}）
     * @throws BizException {@code 40001} 记录不存在/非本人/参数非法
     */
    @Transactional
    public QualificationSubmitResult updateQualification(Long userId, long certId,
            QualificationUpdateRequest request) {
        CertEntity existing = requireOwnedCert(userId, certId);
        if (request == null || request.isEmpty()) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        UpdateWrapper<CertEntity> update = new UpdateWrapper<CertEntity>().eq("id", certId);

        if (request.mediaIds() != null) {
            if (request.mediaIds().isEmpty()) {
                throw BizException.of(ErrorCode.PARAM_INVALID);
            }
            String imageRef = request.mediaIds().get(0);
            if (imageRef == null || imageRef.isBlank()) {
                throw BizException.of(ErrorCode.PARAM_INVALID);
            }
            mediaService.ensureOwned(userId, imageRef);
            update.set("ocr_image_ref", imageRef);
        }
        if (request.certName() != null) {
            update.set("cert_name", requireCertName(request.certName()));
        }
        if (request.nameSource() != null) {
            update.set("name_source", requireNameSource(request.nameSource()));
        }
        certMapper.update(null, update);
        auditLogWriter.write(AuditEntry.minimal(userId, OperatorRole.USER,
                AUDIT_ACTION_QUALIFICATION_UPDATE, AUDIT_TARGET_USER, userId));
        return new QualificationSubmitResult(certId, existing.getStatus());
    }

    /**
     * 删除资质（{@code DELETE /cert/qualification/{cert_id}}）。
     *
     * <p>用户显式删除：先清证照原件（媒体已挂到帖子时跳过，避免帖子裂图），再删记录。
     * 已挂载该证的帖子不再展示凭证块（快照不回溯）。</p>
     *
     * @param userId 当前登录用户 ID
     * @param certId 资质 ID
     * @throws BizException {@code 40001} 记录不存在/非本人
     */
    @Transactional
    public void deleteQualification(Long userId, long certId) {
        CertEntity existing = requireOwnedCert(userId, certId);
        if (existing.getOcrImageRef() != null && !existing.getOcrImageRef().isBlank()) {
            mediaService.deleteOwnedMedia(userId, existing.getOcrImageRef());
        }
        certMapper.deleteById(certId);
        auditLogWriter.write(AuditEntry.minimal(userId, OperatorRole.USER,
                AUDIT_ACTION_QUALIFICATION_DELETE, AUDIT_TARGET_USER, userId));
    }

    /**
     * 把 cert 行转成档案条目（证照图签名失败不影响列表，图片置空）。
     *
     * @param userId 当前登录用户 ID
     * @param row    cert 行
     * @return {@link QualificationItem} 档案条目
     */
    private QualificationItem toItem(Long userId, CertEntity row) {
        String imageUrl = null;
        if (row.getOcrImageRef() != null && !row.getOcrImageRef().isBlank()) {
            try {
                imageUrl = mediaService.signOwnedReadUrl(userId, row.getOcrImageRef());
            } catch (BizException e) {
                // 媒体行已被清理（孤儿清理任务）→ 图片缺席，其余字段照常下发
                imageUrl = null;
            }
        }
        return new QualificationItem(row.getId(), row.getCertName(),
                row.getNameSource(), row.getStatus(), imageUrl);
    }

    /**
     * 取本人资质记录（不存在或非本人一律 40001，不透露资源归属）。
     *
     * @param userId 当前登录用户 ID
     * @param certId 资质 ID
     * @return {@link CertEntity} 记录
     * @throws BizException {@code 40001} 记录不存在/非本人
     */
    private CertEntity requireOwnedCert(Long userId, long certId) {
        CertEntity row = certMapper.selectById(certId);
        if (row == null || !userId.equals(row.getUserId())
                || CERT_TYPE_PERSONAL_REALNAME.equals(row.getCertType())) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return row;
    }

    /**
     * 归一化并校验证名长度（去首尾空白；空白视为未填）。
     *
     * @param certName 证名（可空）
     * @return {@link String} 归一化后的证名；空白返回 {@code null}
     * @throws BizException {@code 40001} 超过 {@value #CERT_NAME_MAX_LENGTH} 字
     */
    private String requireCertName(String certName) {
        String normalized = normalizeCertName(certName);
        if (normalized != null && normalized.length() > CERT_NAME_MAX_LENGTH) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return normalized;
    }

    /**
     * 校验证名来源（空值原样返回 {@code null}，历史行可无来源）。
     *
     * @param nameSource 证名来源
     * @return {@link String} {@code ocr}/{@code manual} 或 {@code null}
     * @throws BizException {@code 40001} 非法值
     */
    private String requireNameSource(String nameSource) {
        if (nameSource == null || nameSource.isBlank()) {
            return null;
        }
        if (!NAME_SOURCE_OCR.equals(nameSource) && !NAME_SOURCE_MANUAL.equals(nameSource)) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return nameSource;
    }

    /**
     * 归一化证名（去首尾空白；空白视为未填）。
     *
     * @param certName 证名
     * @return {@link String} 归一化后的证名；空白返回 {@code null}
     */
    private String normalizeCertName(String certName) {
        if (certName == null) {
            return null;
        }
        String trimmed = certName.strip();
        return trimmed.isEmpty() ? null : trimmed;
    }

    /**
     * 取资质当前快照（供 post 域详情读取凭证当前状态；不存在返回 {@code null}）。
     *
     * <p>跨域只暴露本方法与本域 DTO，post 域不接触 {@code cert} 表（编码规范 §4.2）。</p>
     *
     * @param certId 资质 ID（可空——帖子声明行的 {@code cert_id} 在删除后置空）
     * @return {@link CertSnapshot} 快照；{@code certId} 为空或记录不存在返回 {@code null}
     */
    public CertSnapshot findSnapshot(Long certId) {
        if (certId == null) {
            return null;
        }
        CertEntity row = certMapper.selectById(certId);
        return row == null ? null : toSnapshot(row);
    }

    /**
     * 校验资质可被帖子挂载，并返回挂载快照（发布与补挂共用）。
     *
     * <p>只接受本人、{@code approved} 且证名非空的资质；否则一律 {@code 40001}
     * （不区分「不存在/非本人/已失效」，不按 id 探测归属）。资质无有效期概念，不做到期判断。</p>
     *
     * @param userId 当前登录用户 ID
     * @param certId 资质 ID
     * @return {@link CertSnapshot} 挂载快照
     * @throws BizException {@code 40001} 不可挂载
     */
    public CertSnapshot requireAttachable(Long userId, Long certId) {
        if (certId == null) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        CertEntity row = certMapper.selectById(certId);
        if (row == null || !userId.equals(row.getUserId())
                || CERT_TYPE_PERSONAL_REALNAME.equals(row.getCertType())
                || !CERT_STATUS_APPROVED.equals(row.getStatus())
                || row.getCertName() == null || row.getCertName().isBlank()) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return toSnapshot(row);
    }

    /**
     * 把 cert 行转成跨域快照。
     *
     * @param row cert 行
     * @return {@link CertSnapshot} 快照
     */
    private CertSnapshot toSnapshot(CertEntity row) {
        return new CertSnapshot(row.getId(), row.getCertName(), row.getStatus());
    }

    /**
     * 写一条实名核验通过的 cert 记录（status=approved，approved_at=now）。
     *
     * @param userId 用户 ID
     */
    private void writeCertApproved(Long userId) {
        CertEntity entity = new CertEntity();
        entity.setUserId(userId);
        entity.setCertType(CERT_TYPE_PERSONAL_REALNAME);
        entity.setStatus(CERT_STATUS_APPROVED);
        entity.setApprovedAt(LocalDateTime.now());
        entity.setFailCount(0);
        certMapper.insert(entity);
    }

    // ---------------------------------------------------------------------
    // [153] B2-5 ⑤ 认证审核队列：供后台（admin 域）经 service 接口调用
    // （编码规范 §4.2 域间只调 service，admin 不直连本域 Mapper）
    // ---------------------------------------------------------------------

    /** 认证状态：已驳回（人工审核）。 */
    public static final String CERT_STATUS_REJECTED = "rejected";

    /**
     * 按状态分页列出认证记录（审核队列）。
     *
     * @param status   认证状态（如 {@code pending}）
     * @param page     页码（1 起）
     * @param pageSize 每页条数
     * @return {@link CertReviewPage} 当前页 + 总数
     */
    public CertReviewPage listForReview(String status, int page, int pageSize) {
        long total = certMapper.countByStatus(status);
        List<CertEntity> items = certMapper.selectPageByStatus(status, (page - 1) * pageSize, pageSize);
        return new CertReviewPage(items, total, page, pageSize);
    }

    /**
     * 取单条认证记录（供后台审核前校验存在性与当前状态）。
     *
     * @param certId 认证 ID
     * @return {@link CertEntity} 认证记录；不存在返回 {@code null}
     */
    public CertEntity findCert(long certId) {
        return certMapper.selectById(certId);
    }

    /**
     * 落审核结论（只写状态相关列，不做 RBAC 与审计——两者由 admin 域负责）。
     *
     * <p>为什么把 RBAC/审计留给调用方：本方法属 cert 域的**数据操作**；权限与留痕随
     * 「谁在调」而定（后台四角色），放在数据层会让「换个调用方就绕过权限」。</p>
     *
     * @param certId       认证 ID
     * @param approved     true = 通过，false = 驳回
     * @param rejectReason 驳回原因（approved=true 时忽略）
     */
    public void markReviewed(long certId, boolean approved, String rejectReason) {
        CertEntity patch = new CertEntity();
        patch.setId(certId);
        patch.setStatus(approved ? CERT_STATUS_APPROVED : CERT_STATUS_REJECTED);
        patch.setRejectReason(approved ? null : rejectReason);
        patch.setApprovedAt(approved ? LocalDateTime.now() : null);
        certMapper.updateById(patch);
    }

}
