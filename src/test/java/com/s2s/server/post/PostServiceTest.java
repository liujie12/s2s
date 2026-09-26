package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.post.dto.PostCreateRequest;
import com.s2s.server.post.dto.PostDetail;
import com.s2s.server.post.dto.PostStatusResult;
import com.s2s.server.post.dto.PostStatusUpdateRequest;
import com.s2s.server.post.dto.PrecheckResult;
import com.s2s.server.post.entity.PostEntity;
import com.s2s.server.post.mapper.PostMapper;
import com.s2s.server.post.mapper.PostMediaMapper;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

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
    private PostService postService;

    @BeforeEach
    void setUp() {
        postMapper = mock(PostMapper.class);
        mediaMapper = mock(PostMediaMapper.class);
        cryptoFacade = mock(CryptoFacade.class);
        validator = mock(PostValidator.class);
        mediaAssembler = mock(MediaAssembler.class);
        objectMapper = new ObjectMapper();
        postService = new PostService(postMapper, mediaMapper, cryptoFacade, validator, mediaAssembler, objectMapper);

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
                false, List.of(), "phone", "13800138000");

        PostDetail detail = postService.createPost(1L, req);

        assertThat(detail.id()).isEqualTo(100L);
        assertThat(detail.version()).isZero();
        // contact 加密 AAD = post_id（INSERT 后取到的 100）
        verify(cryptoFacade).encrypt(eq("13800138000"), eq("100"));
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
}
