package com.s2s.server.contact;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.auth.IdentityBindingService;
import com.s2s.server.cert.CertService;
import com.s2s.server.chat.ChatCopy;
import com.s2s.server.chat.ContactApplyService;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.constants.NfrMedia;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitEntries;
import com.s2s.server.contact.dto.ContactInfo;
import com.s2s.server.contact.dto.ReportContext;
import com.s2s.server.contact.dto.ReportDetail;
import com.s2s.server.contact.dto.ReportDetailRow;
import com.s2s.server.contact.dto.ReportRequest;
import com.s2s.server.contact.dto.ReportResult;
import com.s2s.server.contact.dto.ReportTicketPage;
import com.s2s.server.contact.dto.ReportTicketRow;
import com.s2s.server.contact.entity.ContactEventEntity;
import com.s2s.server.contact.entity.ReportEntity;
import com.s2s.server.contact.mapper.ContactEventMapper;
import com.s2s.server.contact.mapper.ContactPostMapper;
import com.s2s.server.contact.mapper.ReportMapper;
import com.s2s.server.post.MediaService;
import com.s2s.server.post.PostModerationService;
import com.s2s.server.post.PostStatus;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 联系域服务（[128]；详设 §5.5.1 / §5.5.2）。
 *
 * <p>两个职责，风险等级完全不同，故写在同一个类里但注释分开：</p>
 * <ul>
 *   <li>{@link #viewContact} —— 全系统<b>唯一</b>返回完整联系方式的路径，
 *       承载详设 §5.5.1 九步链路，含唯一解密点与两张表的写入；</li>
 *   <li>{@link #report} —— 举报落库，链路简单。</li>
 * </ul>
 *
 * <p><b>为什么 {@code viewContact} 必须在同一事务内</b>（详设 §5.5.1 第 [7][8] 步、
 * 可观测 §5「审计写入必须与业务操作在同一事务内」）：{@code contact_event} 与
 * {@code audit_log} 都是本操作不可省的产物——事件丢了北极星指标就没数据源，
 * 审计丢了就无法应对个人信息查询投诉。<b>解密成功但留痕失败 = 一次无记录的
 * 个人信息访问</b>，属合规缺口，故任一步失败整体回滚（宁可让用户重试）。</p>
 *
 * <p><b>本类是全库唯一调 {@code CryptoFacade#decrypt} 的地方</b>（编码规范 §1.2 守门：
 * 调用点计数 == 1；静态扫描测试 {@code CryptoFacadeCallSiteTest} 守住）。任何新增
 * 解密调用点都视为架构变更，须评审（详设 §4.3）。</p>
 */
@Service
public class ContactService {

    /** 审计动作：查看完整联系方式（PRD §9.10.1 必留操作「查看用户脱敏信息」）。 */
    public static final String AUDIT_ACTION_CONTACT_VIEW = "contact.view";

    /** 审计动作：新增举报。 */
    public static final String AUDIT_ACTION_REPORT_CREATE = "report.create";

    /** 审计目标对象类型：帖子。 */
    public static final String AUDIT_TARGET_POST = "post";

    /** 新建举报的初始状态（DDL {@code report.status} 默认值）。 */
    private static final String REPORT_STATUS_PENDING = "pending";

    /** 工单已处理状态（后台处理写入）。 */
    private static final String REPORT_STATUS_HANDLED = "handled";

    /** 后台处理动作：打标误报（回撤该举报的风险分贡献）。 */
    public static final String HANDLE_ACTION_FALSE_REPORT = "false_report";

    /** 后台处理动作：判定下架（审核下架被举报帖子）。 */
    public static final String HANDLE_ACTION_OFFLINE = "offline";

    private final ContactRateGuard rateGuard;
    private final ContactPostMapper contactPostMapper;
    private final ContactEventMapper contactEventMapper;
    private final ReportMapper reportMapper;
    private final CryptoFacade cryptoFacade;
    private final AuditLogWriter auditLogWriter;
    private final ObjectMapper objectMapper;
    private final CertService certService;
    private final PostModerationService postModerationService;
    private final MediaService mediaService;
    private final IdentityBindingService identityBindingService;
    private final ContactApplyService contactApplyService;

    /**
     * 构造联系域服务。
     *
     * @param rateGuard             限频与熔断守卫（详设 §5.5.1 第 [2]–[4] 步）
     * @param contactPostMapper     帖子密文材料读取（本域自有 Mapper，见其类注释）
     * @param contactEventMapper    联系事件写入
     * @param reportMapper          举报写入
     * @param cryptoFacade          全系统唯一解密入口
     * @param auditLogWriter        全系统唯一 {@code audit_log} 写入处
     * @param objectMapper          举报凭证 JSON 序列化
     * @param certService           认证域服务（举报方实名门槛/企业权重判定，[153] B2-5 ④）
     * @param postModerationService 帖子治理服务（风险分累计/审核下架，[153] B2-5 ④）
     * @param mediaService          媒体服务（举报凭证归属与 commit 态校验）
     * @param identityBindingService 身份绑定门禁（B2-6a：未绑手机号禁止查看联系方式）
     * @param contactApplyService    联系方式申请链路（需申请帖的取号闸门，R22 / R24）
     */
    public ContactService(ContactRateGuard rateGuard,
            ContactPostMapper contactPostMapper,
            ContactEventMapper contactEventMapper,
            ReportMapper reportMapper,
            CryptoFacade cryptoFacade,
            AuditLogWriter auditLogWriter,
            ObjectMapper objectMapper,
            CertService certService,
            PostModerationService postModerationService,
            MediaService mediaService,
            IdentityBindingService identityBindingService,
            ContactApplyService contactApplyService) {
        this.rateGuard = rateGuard;
        this.contactPostMapper = contactPostMapper;
        this.contactEventMapper = contactEventMapper;
        this.reportMapper = reportMapper;
        this.cryptoFacade = cryptoFacade;
        this.auditLogWriter = auditLogWriter;
        this.objectMapper = objectMapper;
        this.certService = certService;
        this.postModerationService = postModerationService;
        this.mediaService = mediaService;
        this.identityBindingService = identityBindingService;
        this.contactApplyService = contactApplyService;
    }

    /**
     * 查看完整联系方式（详设 §5.5.1 全链路；{@code GET /posts/{id}/contact}）。
     *
     * <p>执行次序（次序本身是规格，不可调整为并行或换序）：</p>
     * <ol>
     *   <li>登录态 —— 由 controller 的 40101 前置（未登录一律拒绝，使换 IP 无法
     *       绕过账号维度，安全 §3）；</li>
     *   <li>熔断冻结 → {@code 42903}（{@link ContactRateGuard#assertNotFrozen}）；</li>
     *   <li>三维日限（账号 30 / 设备 30 / IP 100）→ {@code 42902}；</li>
     *   <li>突发检测（1min ≥10 次 → 写当日冻结标记）→ {@code 42903}；</li>
     *   <li>帖子可见性 → {@code 41001}；</li>
     *   <li>{@code CryptoFacade} 解密（AAD = {@code post_id}）；</li>
     *   <li>写 {@code contact_event}（北极星辅助指标唯一统计点）；</li>
     *   <li>写 {@code audit_log}（合规留痕，与 [7] <b>同事务</b>）；</li>
     *   <li>返回完整联系方式 + 账号维剩余次数。</li>
     * </ol>
     *
     * <p><b>配额先于可见性判定</b>（[3][4] 在 [5] 之前）是详设给的次序，不是笔误：
     * 对不存在或已下架的帖子探测同样要计入配额，否则按 id 遍历探测可绕过限频。</p>
     *
     * @param viewerId   当前登录用户 ID（controller 已保证非 null）
     * @param postId     帖子 ID
     * @param dimensions 本次请求的限频维度（账号/设备/IP + 自然日）
     * @return {@link ContactInfo} 完整联系方式 + 账号维剩余次数
     * @throws BizException {@code 42903} 冻结 / {@code 42902} 日限 / {@code 41001} 不可见
     */
    @Transactional
    public ContactInfo viewContact(Long viewerId, Long postId,
            RateLimitEntries.RateLimitDimensions dimensions) {
        LocalDate today = dimensions.today();

        // [1.5] 身份门禁（B2-6a / 架构 §5.1.1 门禁②）：未绑定手机号禁止查看联系方式
        identityBindingService.requirePhoneBound(viewerId);

        // [1.6] 需申请帖的取号闸门（R22 / R24）：先于三维限频，避免未获同意的申请人
        //       白耗当日看号次数；帖子不存在/不可见时不在这里拦截，保持既有探测口径
        requireApplyApprovedIfNeeded(viewerId, postId);

        // [2] 熔断冻结 → 42903
        rateGuard.assertNotFrozen(viewerId, today);
        // [3] 三维日限 → 42902
        rateGuard.checkDailyLimits(dimensions);
        // [4] 突发检测 → 42903（超限时落当日冻结标记）
        rateGuard.checkBurst(dimensions);

        // [5] 帖子可见性 → 41001
        Map<String, Object> row = contactPostMapper.selectContactRow(postId);
        if (row == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        if (PostStatus.isGoneForOthers((String) row.get("status"))) {
            // 与详情接口同一口径（PostStatus 是状态语义唯一落点），
            // 且与「行不存在」同码——不区分可避免按 id 探测帖子存在性。
            throw BizException.of(ErrorCode.POST_GONE);
        }

        Long ownerId = toLong(row.get("user_id"));
        String channel = (String) row.get("contact_channel");
        byte[] ciphertext = (byte[]) row.get("contact_value_enc");
        Integer keyVersion = toInteger(row.get("key_version"));
        if (channel == null && ciphertext == null && keyVersion == null) {
            // 2026-11-02：发布时联系方式改为选填（V31 起三列可空），三列全空即
            // 「该帖未留联系方式」的合法形态——回 41002 引导对方补充（§7.8），
            // 不是数据异常，更不该落 50001。
            throw BizException.of(ErrorCode.CONTACT_ABSENT);
        }
        if (ownerId == null || channel == null || ciphertext == null || keyVersion == null) {
            // 三列只缺一部分说明数据被绕过应用层写入（全空已在上方按合法形态拦下）。
            // 不猜、不兜底：缺任何一列都无法安全地继续（尤其 keyVersion，猜错会解出乱码）。
            throw new IllegalStateException("post " + postId + " 联系方式三列不完整，"
                    + "无法解密（contact_channel/contact_value_enc/key_version 应均非空或均空）");
        }

        // [6] 唯一解密点：AAD = post_id（与 [125] 加密侧 String.valueOf(post.getId()) 逐字一致）
        String contactValue = cryptoFacade.decrypt(ciphertext, String.valueOf(postId), keyVersion);

        // [7] 联系事件（北极星辅助指标唯一统计点）
        ContactEventEntity event = new ContactEventEntity();
        event.setPostId(postId);
        event.setFromUserId(viewerId);
        event.setToUserId(ownerId);
        event.setChannelType(channel);
        contactEventMapper.insert(event);

        // [8] 审计留痕（与 [7] 同事务；用户触发的解密留痕 operator_role 取 user，
        //     不再用 system 兜底 —— 依据 DEC-11 / [147]）
        auditLogWriter.write(AuditEntry.minimal(viewerId, OperatorRole.USER,
                AUDIT_ACTION_CONTACT_VIEW, AUDIT_TARGET_POST, postId));

        // [9] 返回完整值 + 账号维剩余次数（剩余量在日限计数之后读取，故已含本次消耗）
        return new ContactInfo(channel, contactValue, rateGuard.remainingToday(viewerId, today));
    }

    /**
     * 需申请帖的取号闸门（R22 / R24）。
     *
     * <p>只拦「可见 + 需申请 + 非发布者 + 未获同意」这一种组合：
     * 帖子不存在或对他人不可见时放行给后续「限频 → 可见性」链路——否则按 id 探测
     * 就会在限频之前拿到 41001，破坏既有「探测同样计入配额」的保护。</p>
     *
     * <p>已同意者不在这里短路：他们继续走三维限频、可见性与同事务审计（R22）。</p>
     *
     * @param viewerId 当前登录用户 ID
     * @param postId   帖子 ID
     * @throws BizException {@code 40305}，文案为「该发布者设置了查看联系方式需申请」
     */
    private void requireApplyApprovedIfNeeded(Long viewerId, Long postId) {
        Map<String, Object> gate = contactPostMapper.selectApplyGateRow(postId);
        if (gate == null) {
            return;
        }
        if (PostStatus.isGoneForOthers((String) gate.get("status"))) {
            return;
        }
        Long ownerId = toLong(gate.get("user_id"));
        Integer applyRequired = toInteger(gate.get("contact_apply_required"));
        boolean gated = applyRequired != null && applyRequired == 1
                && ownerId != null && !ownerId.equals(viewerId);
        if (gated && !contactApplyService.hasApprovedAccess(postId, viewerId)) {
            throw BizException.of(ErrorCode.NO_PERMISSION, ChatCopy.APPLY_REQUIRED);
        }
    }

    /**
     * 举报帖子（详设 §5.5.2；{@code POST /posts/{id}/report}）。
     *
     * <p>频次控制不在本方法：契约与详设 §3.4 行 8 给了独立轨
     * {@code rl:report:uid:{userId}:1d} → {@code 42903}，由 controller 的
     * {@code @RateLimit(REPORT_UID)} 声明——举报没有「必须按特定次序编排」的需求，
     * 走注解驱动即可，不必像 {@link #viewContact} 那样命令式。</p>
     *
     * <p>{@code evidence} 落 {@code report.evidence} JSON 列；空列表与 {@code null}
     * 均落 {@code null}（不落 {@code "[]"}——语义上前者等价，且能让「无凭证」在库里
     * 只有一个表示法）。</p>
     *
     * @param reporterId 举报者 user_id（controller 已保证非 null）
     * @param postId     被举报帖子 ID
     * @param request    举报载荷（{@code reason} 必填，合法性由 controller 校验）
     * @return {@link ReportResult}（举报 ID + 初始状态 pending）
     * @throws BizException {@code 41001}（帖子不存在或对他人不可见）
     */
    @Transactional
    public ReportResult report(Long reporterId, Long postId, ReportRequest request) {
        // [153] B2-5 ④ §9.10.3 举报方门槛：仅已实名用户可提交举报。
        // 用既有码 40305（无权限）—— 不新增错误码（红线），语义上「未实名 = 不具备该权限」。
        if (!certService.isRealnamePassed(reporterId)) {
            throw BizException.of(ErrorCode.NO_PERMISSION);
        }
        Map<String, Object> row = contactPostMapper.selectContactRow(postId);
        if (row == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        if (PostStatus.isGoneForOthers((String) row.get("status"))) {
            // 与 {@link #viewContact} 同一份可见性口径（PostStatus 是状态语义唯一落点）：
            // 对他人不可见的帖子既不能看联系方式，也不该被举报。两条链路若各判一半，
            // 同一份口径就会给出两种行为（[128] 代码评审 #4）。
            throw BizException.of(ErrorCode.POST_GONE);
        }
        Long reportedUserId = toLong(row.get("user_id"));
        if (reportedUserId == null) {
            throw new IllegalStateException("post " + postId + " 缺 user_id，无法确定被举报人");
        }

        // [153] B2-5 ④ §9.10.3 风险分 = 原因分 × 举报方权重（企业认证 ×1.5）。
        // 权重落 report.weight 列（评审/回撤都靠它，不能只存在内存里）。
        return createReport(reporterId, postId, reportedUserId, request.reason(),
                request.remark(), request.evidence(), true);
    }

    /**
     * 会话内举报落库（U7；R29 / KTD10）。
     *
     * <p>与 {@link #report} 的差别只有两处：<b>不做帖子可见性前置校验</b>（帖子下架后
     * 仍可举报），被举报人由调用方按「会话对方」传入。实名门槛、风险分、自动下架判定与
     * 审计留痕完全复用同一实现——两处各写一遍会让「举报是否计入风险分」出现两个答案。</p>
     *
     * <p><b>误拦反馈（{@code misblock}）不累计风险分</b>：它反馈的是审核误判，不是对被举报
     * 帖子的指控；若照原因分表累计，被拦的一方会替审核系统背分，甚至触发自动下架。</p>
     *
     * @param reporterId     举报人 user_id
     * @param postId         会话所锚定的帖子 ID（下架不影响）
     * @param reportedUserId 被举报人 user_id（会话对方）
     * @param reason         举报原因（调用方已按 {@link ReportReason} 白名单校验）
     * @param description    落 {@code report.description} 的描述（误拦反馈含原文摘要）
     * @param evidence       证据 media_ids（可空）
     * @return {@link ReportResult} 举报 ID + 初始状态 pending
     * @throws BizException {@code 40305} 未实名；{@code 41001} 帖子行不存在
     */
    @Transactional
    public ReportResult reportInConversation(Long reporterId, Long postId, Long reportedUserId,
            String reason, String description, List<String> evidence) {
        if (!certService.isRealnamePassed(reporterId)) {
            throw BizException.of(ErrorCode.NO_PERMISSION);
        }
        if (contactPostMapper.selectContactRow(postId) == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        boolean accumulateRisk = !ReportReason.MISBLOCK.dbValue().equals(reason);
        return createReport(reporterId, postId, reportedUserId, reason, description, evidence,
                accumulateRisk);
    }

    /**
     * 举报落库的唯一写入实现（帖子举报与会话内举报共用）。
     *
     * <p><b>凭证先校验后落库</b>：{@code evidence} 由客户端传入，未经校验的 ID 既可能是
     * 伪造/他人媒体（后台复核时越权取图），也可能是未 commit 的空对象（取图 404）。
     * 故在计分与写库之前统一过 {@link #validateEvidence}，失败即整条举报不落库 ——
     * 宁可让用户重选图片，也不收下一条无法复核的工单。</p>
     *
     * @param reporterId     举报人 user_id
     * @param postId         被举报帖子 ID
     * @param reportedUserId 被举报人 user_id
     * @param reason         举报原因（{@code report.reason} 枚举值）
     * @param description    举报描述（落 {@code report.description}）
     * @param evidence       证据 media_ids（可空；空列表与 {@code null} 均落 {@code null}）
     * @param accumulateRisk 是否累计风险分并参与自动下架判定
     * @return {@link ReportResult} 举报 ID + 初始状态 pending
     * @throws BizException 凭证非法（越权/未 commit/非图片/超上限）→ 40001
     */
    private ReportResult createReport(Long reporterId, Long postId, Long reportedUserId,
            String reason, String description, List<String> evidence, boolean accumulateRisk) {
        validateEvidence(reporterId, evidence);
        // [153] B2-5 ④ §9.10.3 风险分 = 原因分 × 举报方权重（企业认证 ×1.5）。
        // 权重落 report.weight 列（评审/回撤都靠它，不能只存在内存里）。
        int contribution = accumulateRisk
                ? ReportRiskScore.of(reason, certService.isEnterpriseVerified(reporterId))
                : 0;

        ReportEntity entity = new ReportEntity();
        entity.setPostId(postId);
        entity.setReporterId(reporterId);
        // 被举报人由服务端派生（帖子发布者 / 会话对方），不接受客户端指定——
        // 由客户端指定「举报谁」等于给了一条伪造他人被举报记录的路径。
        entity.setReportedUserId(reportedUserId);
        entity.setReason(reason);
        // 契约字段名 remark → 列名 description（KTD4 同类漂移，映射只在此处）
        entity.setDescription(description);
        entity.setEvidence(toEvidenceJson(evidence));
        entity.setWeight(contribution);
        entity.setStatus(REPORT_STATUS_PENDING);
        // is_false_report / handler_id / handled_at 不写：由运营侧（后台工单处理）写入。
        reportMapper.insert(entity);

        if (accumulateRisk) {
            // 累计到 post.risk_score；≥ 阈值即自动下架（§9.10.3），随后进人工复核队列。
            // 审计归属：改动由该举报触发，故记 reporterId + user（真实触发人），
            // 而非 SYSTEM —— 留痕要能回答「谁的操作导致了这次下架」。
            int cumulative = postModerationService.applyRiskDelta(postId, contribution);
            if (ReportRiskScore.shouldAutoOffline(cumulative)) {
                postModerationService.auditTakedown(postId, reporterId, OperatorRole.USER);
            }
        }

        // 举报成功同写 audit_log（详设 §5.5.2），与举报落库同事务；
        // 用户触发留痕 operator_role 取 user（DEC-11 / [147]）。
        auditLogWriter.write(AuditEntry.minimal(reporterId, OperatorRole.USER,
                AUDIT_ACTION_REPORT_CREATE, AUDIT_TARGET_POST, postId));

        return new ReportResult(entity.getId(), entity.getStatus());
    }

    /**
     * 取举报工单的定位信息（后台复核会话正文用，U7）。
     *
     * <p>只回「帖子 + 双方用户 + 原因」，不回描述与凭证：后台列表已经展示原因，
     * 正文复核只需要据此定位会话，多回内容等于把举报材料多开一个出口。</p>
     *
     * @param reportId 举报 ID
     * @return {@link ReportContext} 工单定位信息
     * @throws BizException {@code 41001} 举报不存在
     */
    public ReportContext reportContext(long reportId) {
        ReportEntity report = reportMapper.selectById(reportId);
        if (report == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        return new ReportContext(report.getId(), report.getPostId(), report.getReporterId(),
                report.getReportedUserId(), report.getReason());
    }

    /**
     * 单条举报工单详情（后台复核入口；PRD §9.10.1 ④）。
     *
     * <p><b>与 {@link #reportContext} 分开而不是扩参数</b>：后者只用于定位会话正文，
     * 刻意不回描述与凭证（材料每多一个出口就多一处泄露面）；本方法只服务于后台
     * 复核页，明文交出的前提是调用方在入口处已做 RBAC 与查看留痕。</p>
     *
     * @param reportId 举报 ID
     * @return {@link ReportDetail} 含补充说明与凭证 media_ids（无凭证时为空列表）
     * @throws BizException 举报不存在 → 40001（后台口径：工单不存在属参数问题）
     */
    public ReportDetail reportDetailForAdmin(long reportId) {
        ReportDetailRow row = reportMapper.selectDetailById(reportId);
        if (row == null) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return new ReportDetail(row.reportId(), row.postId(), row.postTitle(), row.reason(),
                row.description(), parseEvidence(row.evidenceJson()), row.weight(), row.status(),
                row.isFalseReport(), row.riskScore(), row.createdAt(), row.handledAt(),
                row.handlerId());
    }

    /**
     * 分页列出举报工单（[153] B2-5 ④；供后台经 service 接口调用）。
     *
     * <p>{@code reason} 可空：空=不按原因筛选；传「误拦」即把误拦反馈单独拉出复核（R28）。</p>
     *
     * @param status   工单状态（如 {@code pending}）
     * @param reason   举报原因筛选（可空）
     * @param page     页码（1 起）
     * @param pageSize 每页条数
     * @return {@link ReportTicketPage} 当前页 + 总数（按帖子累计风险分降序）
     */
    public ReportTicketPage listReportsForAdmin(String status, String reason, int page,
            int pageSize) {
        long total = reportMapper.countByStatus(status, reason);
        List<ReportTicketRow> items =
                reportMapper.selectPageByStatus(status, reason, (page - 1) * pageSize, pageSize);
        return new ReportTicketPage(items, total, page, pageSize);
    }

    /**
     * 处理举报工单（[153] B2-5 ④；PRD §9.10.1 ④）。
     *
     * <p>两个动作（互斥）：
     * <ul>
     *   <li>{@link #HANDLE_ACTION_FALSE_REPORT} —— 打标误报：置 {@code is_false_report=1}
     *       并<b>回撤</b>该举报的风险分贡献（§9.10.3「误报不计入累计」）；</li>
     *   <li>{@link #HANDLE_ACTION_OFFLINE} —— 判定下架：对被举报帖子执行审核下架
     *       （{@code status_reason=2}）。</li>
     * </ul>
     * 两动作都置工单为 {@code handled} 并记处理人与时间。已处理的工单再处理 → 40001
     * （幂等靠状态判定，不靠重复执行）。</p>
     *
     * @param reportId    举报 ID
     * @param handlerId   处理人 ID（后台管理员）
     * @param handlerRole 处理人角色（审计用）
     * @param action      处理动作（见上）
     * @throws BizException 举报不存在 → 41001；动作非法 / 工单已处理 → 40001
     */
    @Transactional
    public void handleReport(long reportId, Long handlerId, OperatorRole handlerRole,
            String action) {
        boolean falseReport = HANDLE_ACTION_FALSE_REPORT.equals(action);
        boolean offline = HANDLE_ACTION_OFFLINE.equals(action);
        if (!falseReport && !offline) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        ReportEntity report = reportMapper.selectById(reportId);
        if (report == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        if (!REPORT_STATUS_PENDING.equals(report.getStatus())) {
            // 已处理：不重复回撤/重复下架（重复回撤会把风险分压到 0，掩盖后续举报）
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        ReportEntity patch = new ReportEntity();
        patch.setId(reportId);
        patch.setStatus(REPORT_STATUS_HANDLED);
        patch.setHandlerId(handlerId);
        patch.setHandledAt(java.time.LocalDateTime.now());
        patch.setIsFalseReport(falseReport ? 1 : 0);
        reportMapper.updateById(patch);

        if (falseReport) {
            int contribution = report.getWeight() == null ? 0 : report.getWeight();
            postModerationService.applyRiskDelta(report.getPostId(), -contribution);
        } else {
            postModerationService.auditTakedown(report.getPostId(), handlerId, handlerRole);
        }
    }

    /**
     * 统计某叶子类目下帖子在时间窗内被联系的次数（[153] B2-5 §9.10.2 达标判定用）。
     *
     * <p>供 {@code ops} 域经 service 接口调用（域间只调 service，编码规范 §4.2）。</p>
     *
     * @param leafCategoryId 叶子类目 ID
     * @param from           窗口起（含）
     * @param to             窗口止（不含）
     * @return long 联系事件数
     */
    public long countContactsByLeafBetween(int leafCategoryId, java.time.LocalDateTime from,
            java.time.LocalDateTime to) {
        return contactPostMapper.countContactsByLeafBetween(leafCategoryId, from, to);
    }

    /**
     * 校验举报凭证（media_ids）：数量上限、非空、属于举报人本人、已 commit 的图片。
     *
     * <p><b>为什么必须在写入侧校验而不是只信 DTO</b>：{@code @Size(max=3)} 只约束条数，
     * 约束不了「这个 media_id 是谁的」与「它是否真的传完了」。若不校验，举报人可塞入
     * 他人 media_id（后台复核按 ID 取图即越权查看他人内容），或塞入只签了票据、
     * 从未 commit 的 ID（对象不存在，后台取图 404）。两类都让工单无法复核。</p>
     *
     * <p>空列表与 {@code null} 合法（凭证是加分项、不是受理门槛，契约 {@code required}
     * 只有 {@code reason}）。任一 ID 非法即整条举报拒绝（40001），不做「剔除坏项后
     * 收下剩余项」——静默丢凭证会让用户以为证据已提交。</p>
     *
     * @param reporterId 举报人 user_id（归属校验基准）
     * @param evidence   证据 media_ids（可空）
     * @throws BizException 超上限 / 含空值 / 越权 / 未 commit / 非图片 → 40001
     */
    private void validateEvidence(Long reporterId, List<String> evidence) {
        if (evidence == null || evidence.isEmpty()) {
            return;
        }
        if (evidence.size() > NfrMedia.REPORT_EVIDENCE_MAX) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        for (String mediaId : evidence) {
            if (mediaId == null || mediaId.isBlank()) {
                throw BizException.of(ErrorCode.PARAM_INVALID);
            }
            mediaService.ensureOwnedCommittedImage(reporterId, mediaId);
        }
    }

    /**
     * 把 {@code report.evidence} 的 JSON 文本解析为 media_id 列表（后台复核用）。
     *
     * <p>与 {@link #toEvidenceJson} 互逆：写入侧受控，故解析失败按缺陷处理、直接抛
     * {@link IllegalStateException}，不把「凭证读不出来」静默降级成「该举报没有凭证」——
     * 后者会让运营误判「举报人没举证」。</p>
     *
     * @param evidenceJson 库内 JSON 文本（可空）
     * @return {@link List} media_id 列表；null / 空白时为空列表（不返回 null，
     *         便于调用方直接遍历）
     * @throws IllegalStateException JSON 损坏时抛出（写入侧受控，失败即缺陷）
     */
    private List<String> parseEvidence(String evidenceJson) {
        if (evidenceJson == null || evidenceJson.isBlank()) {
            return List.of();
        }
        try {
            return objectMapper.readValue(evidenceJson, new TypeReference<List<String>>() { });
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("report.evidence 解析失败: " + evidenceJson, exception);
        }
    }

    /**
     * 把证据媒体 ID 列表序列化为 JSON 文本（不落 {@code "[]"}，见 {@link #report}）。
     *
     * @param evidence 证据媒体 ID 列表（可为 null 或空）
     * @return {@link String} JSON 数组文本；null / 空列表时为 {@code null}
     * @throws IllegalStateException 序列化失败时抛出（写入侧受控，失败即缺陷，
     *         静默落 null 会让「有凭证」变成「无凭证」且无从发现）
     */
    private String toEvidenceJson(List<String> evidence) {
        if (evidence == null || evidence.isEmpty()) {
            return null;
        }
        try {
            return objectMapper.writeValueAsString(evidence);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("report.evidence 序列化失败: " + evidence, exception);
        }
    }

    /**
     * 把 JDBC 取回的数值列统一转 {@link Long}。
     *
     * @param value 列值（{@code Long}/{@code Integer}/其他 {@code Number} 或 null）
     * @return {@link Long}；非数值或 null 时返回 {@code null}
     */
    private Long toLong(Object value) {
        return value instanceof Number number ? number.longValue() : null;
    }

    /**
     * 把 JDBC 取回的数值列统一转 {@link Integer}。
     *
     * @param value 列值（{@code Integer}/{@code Long} 或 null）
     * @return {@link Integer}；非数值或 null 时返回 {@code null}
     */
    private Integer toInteger(Object value) {
        return value instanceof Number number ? number.intValue() : null;
    }
}
