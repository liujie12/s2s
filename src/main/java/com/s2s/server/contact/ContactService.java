package com.s2s.server.contact;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitEntries;
import com.s2s.server.contact.dto.ContactInfo;
import com.s2s.server.contact.dto.ReportRequest;
import com.s2s.server.contact.dto.ReportResult;
import com.s2s.server.contact.entity.ContactEventEntity;
import com.s2s.server.contact.entity.ReportEntity;
import com.s2s.server.contact.mapper.ContactEventMapper;
import com.s2s.server.contact.mapper.ContactPostMapper;
import com.s2s.server.contact.mapper.ReportMapper;
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

    private final ContactRateGuard rateGuard;
    private final ContactPostMapper contactPostMapper;
    private final ContactEventMapper contactEventMapper;
    private final ReportMapper reportMapper;
    private final CryptoFacade cryptoFacade;
    private final AuditLogWriter auditLogWriter;
    private final ObjectMapper objectMapper;

    /**
     * 构造联系域服务。
     *
     * @param rateGuard          限频与熔断守卫（详设 §5.5.1 第 [2]–[4] 步）
     * @param contactPostMapper  帖子密文材料读取（本域自有 Mapper，见其类注释）
     * @param contactEventMapper 联系事件写入
     * @param reportMapper       举报写入
     * @param cryptoFacade       全系统唯一解密入口
     * @param auditLogWriter     全系统唯一 {@code audit_log} 写入处
     * @param objectMapper       举报凭证 JSON 序列化
     */
    public ContactService(ContactRateGuard rateGuard,
            ContactPostMapper contactPostMapper,
            ContactEventMapper contactEventMapper,
            ReportMapper reportMapper,
            CryptoFacade cryptoFacade,
            AuditLogWriter auditLogWriter,
            ObjectMapper objectMapper) {
        this.rateGuard = rateGuard;
        this.contactPostMapper = contactPostMapper;
        this.contactEventMapper = contactEventMapper;
        this.reportMapper = reportMapper;
        this.cryptoFacade = cryptoFacade;
        this.auditLogWriter = auditLogWriter;
        this.objectMapper = objectMapper;
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
        if (ownerId == null || ciphertext == null || keyVersion == null) {
            // 三列均为 NOT NULL（DDL V1:154/168/189），取到 null 说明数据被绕过应用层写入。
            // 不猜、不兜底：缺任何一列都无法安全地继续（尤其 keyVersion，猜错会解出乱码）。
            throw new IllegalStateException("post " + postId + " 联系方式三列不完整，"
                    + "无法解密（contact_channel/contact_value_enc/key_version 应均非空）");
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

        // [8] 审计留痕（与 [7] 同事务；operator_role 取 system，理由见 OperatorRole 类注释
        //     与说明文档 §2.9 DEC-11）
        auditLogWriter.write(AuditEntry.minimal(viewerId, OperatorRole.SYSTEM,
                AUDIT_ACTION_CONTACT_VIEW, AUDIT_TARGET_POST, postId));

        // [9] 返回完整值 + 账号维剩余次数（剩余量在日限计数之后读取，故已含本次消耗）
        return new ContactInfo(channel, contactValue, rateGuard.remainingToday(viewerId, today));
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

        ReportEntity entity = new ReportEntity();
        entity.setPostId(postId);
        entity.setReporterId(reporterId);
        // 被举报人取自帖子的发布者（DDL 该列非空，且不许客户端传——由客户端指定
        // 「举报谁」等于给了一条伪造他人被举报记录的路径）。
        entity.setReportedUserId(reportedUserId);
        entity.setReason(request.reason());
        // 契约字段名 remark → 列名 description（KTD4 同类漂移，映射只在此处）
        entity.setDescription(request.remark());
        entity.setEvidence(toEvidenceJson(request.evidence()));
        entity.setStatus(REPORT_STATUS_PENDING);
        // weight / is_false_report / handler_id / handled_at 不写：Batch1 无运营后台，
        // 一律走 DDL 默认值（详见 ReportEntity 类注释）。
        reportMapper.insert(entity);

        // 举报成功同写 audit_log（详设 §5.5.2），与举报落库同事务。
        auditLogWriter.write(AuditEntry.minimal(reporterId, OperatorRole.SYSTEM,
                AUDIT_ACTION_REPORT_CREATE, AUDIT_TARGET_POST, postId));

        return new ReportResult(entity.getId(), entity.getStatus());
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
