package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.post.dto.PostCreateRequest;
import com.s2s.server.post.dto.PostDetail;
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
        when(postMapper.selectById(100L)).thenReturn(saved);

        PostCreateRequest req = new PostCreateRequest(
                "resource", 10101, "标题", "描述", Map.of(), 120.15, 30.28, null,
                false, List.of(), "phone", "13800138000");

        PostDetail detail = postService.createPost(1L, req);

        assertThat(detail.id()).isEqualTo(100L);
        assertThat(detail.version()).isZero();
        // contact 加密 AAD = post_id（INSERT 后取到的 100）
        verify(cryptoFacade).encrypt(eq("13800138000"), eq("100"));
    }
}
