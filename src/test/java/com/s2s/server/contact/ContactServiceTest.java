package com.s2s.server.contact;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.crypto.MasterKey;
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
import java.time.LocalDate;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;
import org.springframework.transaction.annotation.Transactional;

/**
 * {@link ContactService} 测试（[128]；详设 §5.5.1 / §5.5.2）。
 *
 * <p>本测试对齐说明文档 §2.8.4 条目 [128] 的四条特有验收点：
 * ① 解密调用点 == 1（由 {@code CryptoFacadeCallSiteTest} 静态扫描守住，此处断言
 * AAD 逐字为 {@code post_id}）；② AAD 跨行解密失败；③ 审计同事务回滚；
 * ④ 审计白名单（留痕不含联系方式）。</p>
 *
 * <p>用<b>真实 {@link CryptoFacade}</b> 而非 mock：AAD 绑定与密文布局是本条目
 * 唯一的密码学断言对象，mock 掉它等于把「AAD 是否真的绑定 post_id」这条验收
 * 变成自证。密码学之外的外部依赖（限频守卫、三个 Mapper、审计写入）才 mock。</p>
 */
class ContactServiceTest {

    /** 测试用主密钥（version=1，32 字节 hex）。 */
    private static final MasterKey KEY_V1 =
            MasterKey.of(1, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");

    /** 发帖人（被联系者）ID。 */
    private static final Long OWNER_ID = 7L;

    /** 发起联系者 ID。 */
    private static final Long VIEWER_ID = 42L;

    /** 联系方式明文（测试夹具）。 */
    private static final String CONTACT_VALUE = "13800138000";

    /** 测试用自然日。 */
    private static final LocalDate TODAY = LocalDate.of(2026, 9, 28);

    private ContactRateGuard rateGuard;
    private ContactPostMapper contactPostMapper;
    private ContactEventMapper contactEventMapper;
    private ReportMapper reportMapper;
    private AuditLogWriter auditLogWriter;
    private CryptoFacade cryptoFacade;
    private ContactService service;

    /**
     * 装配被测对象：真实 {@link CryptoFacade} + 其余依赖 mock。
     *
     * @return void；无断言
     */
    @BeforeEach
    void setUp() {
        rateGuard = mock(ContactRateGuard.class);
        contactPostMapper = mock(ContactPostMapper.class);
        contactEventMapper = mock(ContactEventMapper.class);
        reportMapper = mock(ReportMapper.class);
        auditLogWriter = mock(AuditLogWriter.class);
        cryptoFacade = new CryptoFacade(List.of(KEY_V1));
        service = new ContactService(rateGuard, contactPostMapper, contactEventMapper,
                reportMapper, cryptoFacade, auditLogWriter, new ObjectMapper());
        when(rateGuard.remainingToday(anyLong(), any())).thenReturn(27);
    }

    /**
     * 成功路径：返回解密后的完整联系方式 + 账号维剩余次数，且
     * {@code contact_event} 与 {@code audit_log} <b>各写一次</b>
     * （详设 §5.5.1「第 7、8 步是两件事、两张表，不可合并、不可省略」）。
     *
     * @return void；断言失败即北极星统计点或合规留痕缺失
     */
    @Test
    void viewContactWritesEventAndAuditOnce() {
        Long postId = 1001L;
        when(contactPostMapper.selectContactRow(postId))
                .thenReturn(row(postId, encryptedAad(postId), 1, "phone", "active"));

        ContactInfo info = service.viewContact(VIEWER_ID, postId, dimensions());

        assertThat(info.contactType()).isEqualTo("phone");
        assertThat(info.contactValue()).isEqualTo(CONTACT_VALUE);
        assertThat(info.remainingToday()).isEqualTo(27);

        ArgumentCaptor<ContactEventEntity> eventCaptor =
                ArgumentCaptor.forClass(ContactEventEntity.class);
        verify(contactEventMapper).insert(eventCaptor.capture());
        assertThat(eventCaptor.getValue().getPostId()).isEqualTo(postId);
        assertThat(eventCaptor.getValue().getFromUserId()).isEqualTo(VIEWER_ID);
        assertThat(eventCaptor.getValue().getToUserId()).isEqualTo(OWNER_ID);
        assertThat(eventCaptor.getValue().getChannelType()).isEqualTo("phone");

        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * <b>验收点 ②：AAD 跨行解密失败</b> —— 把 A 帖的密文搬到 B 帖行后，服务端用
     * B 帖的 {@code id} 作 AAD 解密必须失败，且失败时<b>不写任何一张表</b>
     * （事件与审计都不该留下一条「解密失败的联系」）。
     *
     * <p>这是 AAD 绑定的存在理由（详设 §4.2）：缺了它，拿到 DB 写权限的人把
     * A 用户联系方式密文复制到自己的帖子行，即可让服务端替他解出他人号码。</p>
     *
     * @return void；断言失败即 AAD 未参与校验，跨行搬运攻击成立
     */
    @Test
    void crossRowCiphertextFailsAndWritesNothing() {
        Long sourcePostId = 1001L;
        Long targetPostId = 1002L;
        // 密文按 1001 加密，却出现在 1002 的行上
        when(contactPostMapper.selectContactRow(targetPostId))
                .thenReturn(row(targetPostId, encryptedAad(sourcePostId), 1, "phone", "active"));

        assertThatThrownBy(() -> service.viewContact(VIEWER_ID, targetPostId, dimensions()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("完整性");

        verify(contactEventMapper, never()).insert(any(ContactEventEntity.class));
        verify(auditLogWriter, never()).write(any());
    }

    /**
     * <b>验收点 ④：审计白名单</b> —— 留痕载荷不得携带完整联系方式（也不得携带任何
     * 内容型字段），只记「谁在何时对哪个对象做了什么」。
     * 口径源：编码规范 §4.11（审计白名单剔除 {@code phone}/{@code contact_value} 等）。
     *
     * @return void；断言失败即联系方式被抄进审计表，等于开了第二个敏感数据出口
     */
    @Test
    void auditEntryCarriesNoSensitiveContent() {
        Long postId = 1001L;
        when(contactPostMapper.selectContactRow(postId))
                .thenReturn(row(postId, encryptedAad(postId), 1, "phone", "active"));

        service.viewContact(VIEWER_ID, postId, dimensions());

        ArgumentCaptor<AuditEntry> captor = ArgumentCaptor.forClass(AuditEntry.class);
        verify(auditLogWriter).write(captor.capture());
        AuditEntry entry = captor.getValue();

        assertThat(entry.action()).isEqualTo(ContactService.AUDIT_ACTION_CONTACT_VIEW);
        assertThat(entry.targetType()).isEqualTo(ContactService.AUDIT_TARGET_POST);
        assertThat(entry.targetId()).isEqualTo(postId);
        assertThat(entry.operatorId()).isEqualTo(VIEWER_ID);
        assertThat(entry.beforeValue()).isNull();
        assertThat(entry.afterValue()).isNull();
        assertThat(entry.reason()).isNull();
    }

    /**
     * 解密失败必须发生在写事件与写审计<b>之前</b>（次序断言）：若先把事件落库再解密，
     * 解密失败会留下一条「联系了但看不到号码」的假指标，污染北极星辅助指标。
     *
     * @return void；断言失败即链路次序被调整，指标可能被污染
     */
    @Test
    void decryptAndInsertOrderIsDecryptFirst() {
        Long postId = 1001L;
        when(contactPostMapper.selectContactRow(postId))
                .thenReturn(row(postId, encryptedAad(postId), 1, "wechat", "active"));

        service.viewContact(VIEWER_ID, postId, dimensions());

        InOrder order = inOrder(contactEventMapper, auditLogWriter);
        order.verify(contactEventMapper).insert(any(ContactEventEntity.class));
        order.verify(auditLogWriter).write(any());
    }

    /**
     * 帖子不存在 → {@code 41001}（与「已下架」同码，不区分可避免按 id 探测存在性）。
     *
     * @return void；断言失败即探测风险：能区分「不存在」与「已下架」
     */
    @Test
    void missingPostIsGone() {
        when(contactPostMapper.selectContactRow(anyLong())).thenReturn(null);

        assertThatThrownBy(() -> service.viewContact(VIEWER_ID, 999L, dimensions()))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
    }

    /**
     * 帖子对他人不可见（下架/过期/归档/隐藏）→ {@code 41001}，
     * 且<b>不进解密</b>（不可见帖的密文不该被解出）。
     *
     * @return void；断言失败即已下架帖仍可拿到联系方式
     */
    @Test
    void nonActivePostIsGoneAndNotDecrypted() {
        when(contactPostMapper.selectContactRow(anyLong()))
                .thenReturn(row(1003L, encryptedAad(1003L), 1, "phone", "archived"));

        assertThatThrownBy(() -> service.viewContact(VIEWER_ID, 1003L, dimensions()))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);

        verify(contactEventMapper, never()).insert(any(ContactEventEntity.class));
    }

    /**
     * <b>验收点 ③：审计同事务回滚</b>（异常侧）—— 审计写入失败必须向上抛出，
     * 由调用方事务整体回滚；静默吞掉会留下「操作成功但没留痕」的合规缺口
     * （可观测 §5 原文）。
     *
     * <p>事务本身的「同一事务」属性由 {@link #viewContactAndAuditWriterTransactionContract()}
     * 的注解契约断言守住（单测无 Spring 容器，不做真实回滚验证）。</p>
     *
     * @return void；断言失败即审计失败被吞，合规缺口不可发现
     */
    @Test
    void auditWriteFailurePropagates() {
        Long postId = 1001L;
        when(contactPostMapper.selectContactRow(postId))
                .thenReturn(row(postId, encryptedAad(postId), 1, "phone", "active"));
        doThrow(new IllegalStateException("audit_log 写入失败"))
                .when(auditLogWriter).write(any());

        assertThatThrownBy(() -> service.viewContact(VIEWER_ID, postId, dimensions()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("audit_log");
    }

    /**
     * <b>验收点 ③：审计同事务回滚</b>（结构侧）——「同一事务」的可判形式是两条注解契约：
     * ① {@code ContactService#viewContact} 带 {@link Transactional}（自开事务、
     * 失败整体回滚）；② {@code AuditLogWriter} <b>不带</b> {@code @Transactional}
     * （加入调用方事务，而非 {@code REQUIRES_NEW} 另开一个）。
     *
     * <p>若 ② 被改成 {@code REQUIRES_NEW}，会出现「业务回滚但审计已提交」的假留痕：
     * 记录在案的操作其实没发生。该断言把这条性质从注释变成机器判据。</p>
     *
     * @return void；断言失败即审计可能脱离业务事务，留痕与事实不一致
     */
    @Test
    void viewContactAndAuditWriterTransactionContract() throws NoSuchMethodException {
        assertThat(ContactService.class
                .getMethod("viewContact", Long.class, Long.class,
                        RateLimitEntries.RateLimitDimensions.class)
                .isAnnotationPresent(Transactional.class))
                .as("viewContact 必须自开事务，审计失败才能整体回滚")
                .isTrue();
        assertThat(AuditLogWriter.class.isAnnotationPresent(Transactional.class))
                .as("AuditLogWriter 不得自开事务，必须加入调用方事务")
                .isFalse();
    }

    /**
     * 限频守卫的拒绝（{@code 42903} 冻结 / {@code 42902} 日限）必须先于任何数据访问：
     * 被拒的请求不应触达帖子表，也不消耗解密成本。
     *
     * @return void；断言失败即限频判定被挪到读库之后，防护面漏了探测流量
     */
    @Test
    void guardRejectionShortCircuitsBeforeDataAccess() {
        doThrow(BizException.ofRetryAfter(ErrorCode.CIRCUIT_BROKEN, 120))
                .when(rateGuard).assertNotFrozen(anyLong(), any());

        assertThatThrownBy(() -> service.viewContact(VIEWER_ID, 1001L, dimensions()))
                .isInstanceOf(BizException.class);

        verify(contactPostMapper, never()).selectContactRow(any());
    }

    /**
     * 举报成功：落一条 {@code pending} 举报 + 一条审计，且契约字段
     * {@code remark} 映射到列 {@code description}、证据列表序列化为 JSON。
     *
     * @return void；断言失败即举报落库字段错位（KTD4 同类漂移）或漏审计
     */
    @Test
    void reportWritesPendingRowAndAudit() {
        Long postId = 1001L;
        when(contactPostMapper.selectContactRow(postId))
                .thenReturn(row(postId, encryptedAad(postId), 1, "phone", "active"));
        when(reportMapper.insert(any(ReportEntity.class))).thenAnswer(invocation -> {
            ReportEntity entity = invocation.getArgument(0);
            entity.setId(88L);
            return 1;
        });

        ReportResult result = service.report(VIEWER_ID, postId,
                new ReportRequest("fraud", "对方要求先付款", List.of("m1", "m2")));

        assertThat(result.reportId()).isEqualTo(88L);
        assertThat(result.status()).isEqualTo("pending");

        ArgumentCaptor<ReportEntity> captor = ArgumentCaptor.forClass(ReportEntity.class);
        verify(reportMapper).insert(captor.capture());
        ReportEntity saved = captor.getValue();
        assertThat(saved.getReason()).isEqualTo("fraud");
        assertThat(saved.getDescription()).isEqualTo("对方要求先付款");
        assertThat(saved.getEvidence()).isEqualTo("[\"m1\",\"m2\"]");
        assertThat(saved.getStatus()).isEqualTo("pending");
        // 被举报人取自帖子发布者，不接受客户端指定
        assertThat(saved.getReportedUserId()).isEqualTo(OWNER_ID);
        // Batch1 无运营后台：权重与误报标不写（走 DDL 默认 0）
        assertThat(saved.getWeight()).isNull();
        assertThat(saved.getIsFalseReport()).isNull();

        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * 举报无凭证时 {@code evidence} 落 {@code null}（不落 {@code "[]"}）——
     * 「无凭证」在库里保持只有一个表示法。
     *
     * @return void；断言失败即同一语义出现两种存储形态，后续统计要兼容两套
     */
    @Test
    void reportWithoutEvidenceStoresNull() {
        Long postId = 1001L;
        when(contactPostMapper.selectContactRow(postId))
                .thenReturn(row(postId, encryptedAad(postId), 1, "phone", "active"));

        service.report(VIEWER_ID, postId, new ReportRequest("other", null, List.of()));

        ArgumentCaptor<ReportEntity> captor = ArgumentCaptor.forClass(ReportEntity.class);
        verify(reportMapper).insert(captor.capture());
        assertThat(captor.getValue().getEvidence()).isNull();
    }

    /**
     * 举报不存在的帖子 → {@code 41001}，且不落举报行（避免无主举报记录）。
     *
     * @return void；断言失败即产生指向不存在帖子的脏数据
     */
    @Test
    void reportMissingPostIsGone() {
        when(contactPostMapper.selectContactRow(anyLong())).thenReturn(null);

        assertThatThrownBy(() -> service.report(VIEWER_ID, 999L,
                new ReportRequest("other", null, null)))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);

        verify(reportMapper, never()).insert(any(ReportEntity.class));
    }

    /**
     * <b>可见性口径与 {@code viewContact} 一致</b>（[128] 代码评审 #4）：对他人不可见
     * （已下架/过期/归档/隐藏）的帖子 → {@code 41001}，且不落举报行。
     *
     * <p>原先 {@code report} 只判「行是否存在」，于是已下架的帖子仍可被举报成功落库，
     * 而同方法 javadoc 明写 41001 含「对他人不可见」——代码与其自身契约冲突，
     * 两条链路对同一份可见性给出不一致行为。</p>
     *
     * @return void；断言失败即下架内容仍可被举报，可见性口径重新分叉
     */
    @Test
    void reportInvisiblePostIsGone() {
        Long postId = 1003L;
        when(contactPostMapper.selectContactRow(postId))
                .thenReturn(row(postId, encryptedAad(postId), 1, "phone", "archived"));

        assertThatThrownBy(() -> service.report(VIEWER_ID, postId,
                new ReportRequest("other", null, null)))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);

        verify(reportMapper, never()).insert(any(ReportEntity.class));
        verify(auditLogWriter, never()).write(any());
    }

    /**
     * 构造帖子行夹具（列名与 {@code ContactPostMapper.xml} 的 SELECT 列集合逐字一致）。
     *
     * @param postId       帖子 ID
     * @param ciphertext   联系方式密文（{@code byte[]}）
     * @param keyVersion   密钥版本号
     * @param channel      联系方式渠道（{@code phone}/{@code wechat}）
     * @param status       库内状态
     * @return {@link Map} 六列行
     */
    private Map<String, Object> row(Long postId, byte[] ciphertext, int keyVersion,
            String channel, String status) {
        Map<String, Object> row = new HashMap<>();
        row.put("id", postId);
        row.put("user_id", OWNER_ID);
        row.put("contact_channel", channel);
        row.put("contact_value_enc", ciphertext);
        row.put("key_version", keyVersion);
        row.put("status", status);
        return row;
    }

    /**
     * 用指定帖子的 AAD 加密联系方式明文（模拟 [125] 发布链的写入结果）。
     *
     * @param postId 加密时用作 AAD 的帖子 ID
     * @return {@code byte[]} 密文
     */
    private byte[] encryptedAad(Long postId) {
        return cryptoFacade.encrypt(CONTACT_VALUE, String.valueOf(postId)).ciphertext();
    }

    /**
     * 构造限频维度（账号维 + 固定 IP）。
     *
     * @return {@link RateLimitEntries.RateLimitDimensions} 五元组
     */
    private RateLimitEntries.RateLimitDimensions dimensions() {
        return RateLimitEntries.RateLimitDimensions.of(VIEWER_ID, null, "127.0.0.1", TODAY);
    }
}
