package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.ai.AiQuotaGate;
import com.s2s.server.auth.IdentityBindingService;
import com.s2s.server.cert.CertService;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.post.dto.PostCreateRequest;
import com.s2s.server.post.dto.PostDetail;
import com.s2s.server.post.dto.PostStatusResult;
import com.s2s.server.post.dto.PostStatusUpdateRequest;
import com.s2s.server.post.dto.PostUpdateRequest;
import com.s2s.server.post.dto.PrecheckResult;
import com.s2s.server.post.dto.RepostDraft;
import com.s2s.server.post.entity.PostEntity;
import com.s2s.server.post.entity.PostMediaEntity;
import com.s2s.server.post.mapper.PostMapper;
import com.s2s.server.search.AmapPoiClient;
import com.s2s.server.search.CommunityResolver;
import com.s2s.server.post.mapper.PostMediaMapper;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link PostService} 发布落库测试（[125]）。
 *
 * <p>覆盖：contact 双列加密 AAD=post_id、完整度三条件落库、STORE 生成列重查。</p>
 */
class PostServiceTest {

    private PostMapper postMapper;
    private PostMediaMapper mediaMapper;
    private CryptoFacade cryptoFacade;
    private PostValidator validator;
    private MediaAssembler mediaAssembler;
    private ObjectMapper objectMapper;
    private AiQuotaGate aiQuotaGate;
    private IdentityBindingService identityBindingService;
    private AmapPoiClient amapPoiClient;
    private CommunityResolver communityResolver;
    private CertService certService;
    private PostCredentialAssembler credentialAssembler;
    private PostService postService;

    @BeforeEach
    void setUp() {
        postMapper = mock(PostMapper.class);
        mediaMapper = mock(PostMediaMapper.class);
        cryptoFacade = mock(CryptoFacade.class);
        validator = mock(PostValidator.class);
        mediaAssembler = mock(MediaAssembler.class);
        objectMapper = new ObjectMapper();
        aiQuotaGate = mock(AiQuotaGate.class);
        identityBindingService = mock(IdentityBindingService.class);
        amapPoiClient = mock(AmapPoiClient.class);
        communityResolver = mock(CommunityResolver.class);
        certService = mock(CertService.class);
        credentialAssembler = mock(PostCredentialAssembler.class);
        when(communityResolver.resolve(any(), any())).thenReturn(CommunityResolver.CommunityMatch.empty());
        postService = new PostService(postMapper, mediaMapper, cryptoFacade, validator,
                mediaAssembler, objectMapper, aiQuotaGate, identityBindingService,
                amapPoiClient, communityResolver, certService, credentialAssembler);

        when(validator.computeDerived(any(), any(), any()))
                .thenReturn(new PrecheckResult.Derived(true, false, true));
        when(cryptoFacade.encrypt(anyString(), any()))
                .thenReturn(new CryptoFacade.EncryptResult(1, new byte[] {1, 2, 3}));
        // insert 回填自增 id（模拟 MyBatis-Plus @TableId(AUTO)）
        when(postMapper.insert(any(PostEntity.class))).thenAnswer(inv -> {
            inv.getArgument(0, PostEntity.class).setId(100L);
            return 1;
        });
    }

    @Test
    void createPostEncryptsContactWithPostIdAad() {
        PostEntity saved = new PostEntity();
        saved.setId(100L);
        saved.setType("resource");
        saved.setLeafCategoryId(10101);
        saved.setL2CategoryId(101);
        saved.setTitle("t");
        saved.setCompletenessLevel(2);
        saved.setStatus("active");
        saved.setVersion(0L);
        saved.setExpireAt(java.time.LocalDateTime.now());
        // created_at 在真实行里是 NOT NULL DEFAULT CURRENT_TIMESTAMP，[127] 起详情出参读它，
        // 故夹具须与真实行同形（缺它会 NPE，而不是被静默兜底成 null）
        saved.setCreatedAt(java.time.LocalDateTime.now());
        when(postMapper.selectById(100L)).thenReturn(saved);

        PostCreateRequest req = new PostCreateRequest(
                "resource", 10101, "标题", 50.0, "小时", "描述", Map.of(), 120.15, 30.28, null,
                false, List.of(), "phone", "13800138000", null, null);

        PostDetail detail = postService.createPost(1L, req);

        assertThat(detail.id()).isEqualTo(100L);
        assertThat(detail.version()).isZero();
        // B2-6a：发布前必须过「已绑手机号」门禁（架构 §5.1.1 门禁②）
        verify(identityBindingService).requirePhoneBound(1L);
        // contact 加密 AAD = post_id（INSERT 后取到的 100）
        verify(cryptoFacade).encrypt(eq("13800138000"), eq("100"));
    }

    /**
     * 发布：description 缺省（AI 快速发布不采集描述）时归一为空串。
     *
     * <p>`desc` 列 NOT NULL 且无默认值，null 会被 MyBatis-Plus 从 INSERT 省略，
     * 线上表现为 {@code Field 'desc' doesn't have a default value} → 50001
     * （2026-10-17 真机实证）。</p>
     *
     * @return void；断言失败即空描述发布仍会 500
     */
    @Test
    void createPost描述缺省时归一为空串() {
        when(postMapper.selectById(100L)).thenReturn(createSavedRow());
        PostCreateRequest req = new PostCreateRequest(
                "resource", 10101, "标题", 50.0, "小时", null, Map.of(), 120.15, 30.28, null,
                false, List.of(), "phone", "13800138000", true, null);

        postService.createPost(1L, req);

        ArgumentCaptor<PostEntity> captor = ArgumentCaptor.forClass(PostEntity.class);
        verify(postMapper).insert(captor.capture());
        assertThat(captor.getValue().getDescription()).isEmpty();
    }

    /**
     * 发布：ai_assisted=true → 发布成功后扣 1 次 AI 配额（PRD §5.9「仅确认发布才计 1 次」）。
     *
     * @return void；断言失败即 AI 辅助发布不扣配额（配额口径失效）
     */
    @Test
    void createPostAiAssisted扣一次配额() {
        when(postMapper.selectById(100L)).thenReturn(createSavedRow());

        postService.createPost(1L, createReq(Boolean.TRUE));

        verify(aiQuotaGate).increment(eq(1L), any());
    }

    /**
     * 发布：ai_assisted 非 true（false/null）→ 不扣配额。
     *
     * @return void；断言失败即普通发布误扣 AI 配额
     */
    @Test
    void createPost非AiAssisted不扣配额() {
        when(postMapper.selectById(100L)).thenReturn(createSavedRow());

        postService.createPost(1L, createReq(Boolean.FALSE));

        verify(aiQuotaGate, never()).increment(any(), any());
    }

    /**
     * 造发布载荷（B2-4）。
     *
     * @param aiAssisted 是否 AI 辅助生成（可空）
     * @return {@link PostCreateRequest} 载荷
     */
    private static PostCreateRequest createReq(Boolean aiAssisted) {
        return new PostCreateRequest(
                "resource", 10101, "标题", 50.0, "小时", "描述", Map.of(), 120.15, 30.28, null,
                false, List.of(), "phone", "13800138000", aiAssisted, null);
    }

    /**
     * 造发布落库后重查行（含 STORED 生成列与 NOT NULL 时间列）。
     *
     * @return {@link PostEntity} 落库行
     */
    private static PostEntity createSavedRow() {
        PostEntity saved = new PostEntity();
        saved.setId(100L);
        saved.setUserId(1L);
        saved.setType("resource");
        saved.setLeafCategoryId(10101);
        saved.setL2CategoryId(101);
        saved.setTitle("标题");
        saved.setCompletenessLevel(2);
        saved.setStatus("active");
        saved.setVersion(0L);
        saved.setCreatedAt(LocalDateTime.now());
        saved.setExpireAt(LocalDateTime.now().plusDays(7));
        return saved;
    }

    @Test
    void updateStatus动作非法回40001() {
        PostStatusUpdateRequest req = new PostStatusUpdateRequest("delete", 0L);
        assertThatThrownBy(() -> postService.updateStatus(1L, 100L, req))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    @Test
    void updateStatus影响0行回40903() {
        when(postMapper.update(isNull(), any())).thenReturn(0);
        PostStatusUpdateRequest req = new PostStatusUpdateRequest("offline", 3L);
        assertThatThrownBy(() -> postService.updateStatus(1L, 100L, req))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.VERSION_CONFLICT);
    }

    @Test
    void updateStatus下架返回新版本号() {
        when(postMapper.update(isNull(), any())).thenReturn(1);
        PostEntity updated = new PostEntity();
        updated.setId(100L);
        updated.setStatus("archived");
        updated.setStatusReason(0);
        updated.setExpireAt(java.time.LocalDateTime.of(2026, 9, 8, 12, 0));
        updated.setVersion(4L);
        when(postMapper.selectById(100L)).thenReturn(updated);

        PostStatusResult result =
                postService.updateStatus(1L, 100L, new PostStatusUpdateRequest("offline", 3L));
        assertThat(result.status()).isEqualTo("offline");
        assertThat(result.version()).isEqualTo(4L);
    }

    // ---------------------------------------------------------------------
    // [B2-8] 编辑 / 克隆重发
    // ---------------------------------------------------------------------

    /**
     * 编辑：0 行（版本不符 / 非本人 / 非在架）→ 40903，且不触达媒体重设。
     *
     * @return void；断言失败即编辑可越过乐观锁或状态守卫
     */
    @Test
    void updatePost影响0行回40903() {
        when(postMapper.update(isNull(), any())).thenReturn(0);

        assertThatThrownBy(() -> postService.updatePost(1L, 100L, updateReq(null)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.VERSION_CONFLICT);
        verify(mediaMapper, never()).update(isNull(), any());
    }

    /**
     * 编辑：不传联系方式（null）→ 保留原密文，不重新加密；成功返回新版本号。
     *
     * @return void；断言失败即编辑会覆盖原联系方式（安全收窄被破）
     */
    @Test
    void updatePostKeepsContactWhenValueAbsent() {
        when(postMapper.update(isNull(), any())).thenReturn(1);
        when(postMapper.selectById(100L)).thenReturn(activeRow());
        when(mediaMapper.selectList(any())).thenReturn(List.of());
        when(mediaMapper.update(isNull(), any())).thenReturn(0);

        PostDetail detail = postService.updatePost(1L, 100L, updateReq(null));

        assertThat(detail.id()).isEqualTo(100L);
        assertThat(detail.version()).isEqualTo(5L);
        verify(cryptoFacade, never()).encrypt(anyString(), any());
    }

    /**
     * 编辑：传了新联系方式 → 以 AAD=post_id 重新加密。
     *
     * @return void
     */
    @Test
    void updatePostReEncryptsWhenContactProvided() {
        when(postMapper.update(isNull(), any())).thenReturn(1);
        when(postMapper.selectById(100L)).thenReturn(activeRow());
        when(mediaMapper.selectList(any())).thenReturn(List.of());
        when(mediaMapper.update(isNull(), any())).thenReturn(0);

        postService.updatePost(1L, 100L, updateReq("13900139000"));

        verify(cryptoFacade).encrypt(eq("13900139000"), eq("100"));
    }

    /**
     * 重发：帖子不存在 / 非本人 → 41001（不区分，避免按 id 探测）。
     *
     * @return void
     */
    @Test
    void repostMissingOrNotOwner回41001() {
        when(postMapper.selectById(100L)).thenReturn(null);
        assertThatThrownBy(() -> postService.repost(1L, 100L))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);

        PostEntity others = archivedRow();
        others.setUserId(999L);
        when(postMapper.selectById(100L)).thenReturn(others);
        assertThatThrownBy(() -> postService.repost(1L, 100L))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
    }

    /**
     * 重发：在架帖不可重发 → 40001。
     *
     * @return void
     */
    @Test
    void repostActive回40001() {
        when(postMapper.selectById(100L)).thenReturn(activeRow());
        assertThatThrownBy(() -> postService.repost(1L, 100L))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    /**
     * 重发：已下架 → 返回克隆草稿（含媒体、脱敏联系方式、分类可用）。
     *
     * @return void；断言失败即重发拿不到可编辑载荷
     */
    @Test
    void repostReturnsCloneDraft() {
        when(postMapper.selectById(100L)).thenReturn(archivedRow());
        PostMediaEntity media = new PostMediaEntity();
        media.setId(7L);
        when(mediaMapper.selectList(any())).thenReturn(List.of(media));
        when(validator.isLeafAvailable(10101)).thenReturn(true);

        RepostDraft draft = postService.repost(1L, 100L);

        assertThat(draft.sourcePostId()).isEqualTo(100L);
        assertThat(draft.type()).isEqualTo("resource");
        assertThat(draft.leafCategoryId()).isEqualTo(10101);
        assertThat(draft.mediaIds()).containsExactly("7");
        assertThat(draft.contactMask()).isEqualTo("138****8000");
        assertThat(draft.attributes()).containsEntry("a", "b");
        assertThat(draft.addressPrecise()).isTrue();
        assertThat(draft.categoryAvailable()).isTrue();
    }

    /**
     * 重发：原分类被运营停用 → categoryAvailable=false（PRD §8.7 前端须提示重选）。
     *
     * @return void
     */
    @Test
    void repostMarksCategoryUnavailable() {
        when(postMapper.selectById(100L)).thenReturn(archivedRow());
        when(mediaMapper.selectList(any())).thenReturn(List.of());
        when(validator.isLeafAvailable(10101)).thenReturn(false);

        assertThat(postService.repost(1L, 100L).categoryAvailable()).isFalse();
    }

    /**
     * 造编辑载荷（[B2-8]）。
     *
     * @param contactValue 联系方式值；{@code null} 表示保留原密文不改
     * @return {@link PostUpdateRequest} 载荷
     */
    private static PostUpdateRequest updateReq(String contactValue) {
        return new PostUpdateRequest(4L, "resource", 10101, "新标题", 60.0, "小时", "新描述",
                Map.of("k", "v"), 120.15, 30.28, null, false, List.of(),
                contactValue == null ? null : "phone", contactValue, null);
    }

    /**
     * 造在架帖行。
     *
     * @return {@link PostEntity} active 行
     */
    private static PostEntity activeRow() {
        PostEntity post = new PostEntity();
        post.setId(100L);
        post.setUserId(1L);
        post.setType("resource");
        post.setLeafCategoryId(10101);
        post.setL2CategoryId(101);
        post.setTitle("t");
        post.setCompletenessLevel(2);
        post.setStatus("active");
        post.setVersion(5L);
        post.setCreatedAt(LocalDateTime.now());
        post.setExpireAt(LocalDateTime.now().plusDays(7));
        return post;
    }

    /**
     * 造已下架帖行（archived + reason 0 → API offline），含克隆所需字段。
     *
     * @return {@link PostEntity} archived 行
     */
    private static PostEntity archivedRow() {
        PostEntity post = activeRow();
        post.setStatus("archived");
        post.setStatusReason(0);
        post.setPrice(new BigDecimal("50.0"));
        post.setPriceUnit("小时");
        post.setLng(new BigDecimal("120.150000"));
        post.setLat(new BigDecimal("30.280000"));
        post.setContactChannel("phone");
        post.setContactMask("138****8000");
        post.setTemplateValues("{\"a\":\"b\"}");
        post.setCompletenessConditions("{\"required_full\":true,\"address_precise\":true,\"leaf_matched\":true}");
        return post;
    }
}
