package com.s2s.server.post;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.baomidou.mybatisplus.core.conditions.update.UpdateWrapper;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.constants.NfrPost;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.geo.GridIdCalculator;
import com.s2s.server.post.dto.MediaItem;
import com.s2s.server.post.dto.PostCreateRequest;
import com.s2s.server.post.dto.PostDetail;
import com.s2s.server.post.dto.PrecheckResult;
import com.s2s.server.post.entity.PostEntity;
import com.s2s.server.post.entity.PostMediaEntity;
import com.s2s.server.post.mapper.PostMapper;
import com.s2s.server.post.mapper.PostMediaMapper;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 发布服务（[125]；详设 §5.3.2 发布链路十步）。
 *
 * <p>职责：承载 {@code POST /posts} 落库逻辑——校验、grid_id 计算、完整度三条件、
 * contact 双列加密（AAD=post_id）、媒体归属校验与关联、乐观锁 version 初始化。</p>
 */
@Service
public class PostService {

    /** 帖子初始状态：已发布上架。 */
    private static final String STATUS_ACTIVE = "active";

    /** 帖子初始模板版本（TODO：对齐 template 表实际版本）。 */
    private static final int INITIAL_TEMPLATE_VERSION = 1;

    private final PostMapper postMapper;
    private final PostMediaMapper mediaMapper;
    private final CryptoFacade cryptoFacade;
    private final PostValidator validator;
    private final MediaAssembler mediaAssembler;
    private final ObjectMapper objectMapper;

    /**
     * 构造发布服务。
     */
    public PostService(PostMapper postMapper,
            PostMediaMapper mediaMapper,
            CryptoFacade cryptoFacade,
            PostValidator validator,
            MediaAssembler mediaAssembler,
            ObjectMapper objectMapper) {
        this.postMapper = postMapper;
        this.mediaMapper = mediaMapper;
        this.cryptoFacade = cryptoFacade;
        this.validator = validator;
        this.mediaAssembler = mediaAssembler;
        this.objectMapper = objectMapper;
    }

    /**
     * 发布帖子（落库十步）。
     *
     * @param userId 当前用户 ID
     * @param req    发布载荷
     * @return {@link PostDetail}（必带 version，不含完整联系方式）
     */
    @Transactional
    public PostDetail createPost(Long userId, PostCreateRequest req) {
        // [2] 类目 / [4] 敏感词 / [5] 媒体校验（命中即抛）
        validator.validate(userId, req.leafCategoryId(), req.title(), req.description(), req.mediaIds());

        // [6] grid_id
        String gridId = GridIdCalculator.of(req.lng(), req.lat());

        // [7] 完整度三条件 → completeness_conditions JSON
        PrecheckResult.Derived derived =
                validator.computeDerived(req.leafCategoryId(), req.attributes(), req.addressPrecise());

        // [8] INSERT（contact 密文列写空 byte[] 占位）
        PostEntity post = new PostEntity();
        post.setUserId(userId);
        post.setType(req.type());
        post.setLeafCategoryId(req.leafCategoryId());
        post.setTitle(req.title());
        post.setDescription(req.description());
        post.setTemplateValues(toJson(req.attributes()));
        post.setGridId(gridId);
        post.setLng(BigDecimal.valueOf(req.lng()));
        post.setLat(BigDecimal.valueOf(req.lat()));
        post.setAddress(req.address());
        post.setContactChannel(req.contactType());
        post.setContactValueEnc(new byte[0]);
        post.setKeyVersion(0);
        post.setCompletenessConditions(conditionsJson(derived));
        post.setStatus(STATUS_ACTIVE);
        post.setRestricted(0);
        post.setTemplateVersion(INITIAL_TEMPLATE_VERSION);
        post.setExpireAt(LocalDateTime.now().plusDays(NfrPost.VALID_DAYS));
        postMapper.insert(post);

        // [7] contact 双列加密：AAD = post_id，INSERT 后 UPDATE 密文
        CryptoFacade.EncryptResult enc =
                cryptoFacade.encrypt(req.contactValue(), String.valueOf(post.getId()));
        post.setContactValueEnc(enc.ciphertext());
        post.setKeyVersion(enc.keyVersion());
        postMapper.updateById(post);

        // 关联媒体（post_media.post_id 落位）
        linkMedia(userId, post.getId(), req.mediaIds());

        // 重查取 STORED 生成列（l2_category_id / completeness_level）
        PostEntity saved = postMapper.selectById(post.getId());
        return assemble(saved, req, userId);
    }

    /**
     * 关联媒体到帖子（归属校验后更新 post_id）。
     */
    private void linkMedia(Long userId, Long postId, List<String> mediaIds) {
        if (mediaIds == null || mediaIds.isEmpty()) {
            return;
        }
        for (String mediaId : mediaIds) {
            Long id = parseMediaId(mediaId);
            if (id == null) {
                continue;
            }
            PostMediaEntity media = mediaMapper.selectById(id);
            if (media == null || !media.getUserId().equals(userId)) {
                continue;
            }
            media.setPostId(postId);
            mediaMapper.updateById(media);
        }
    }

    /**
     * 组装 PostDetail（本人视角 media 全量）。
     */
    private PostDetail assemble(PostEntity post, PostCreateRequest req, Long userId) {
        List<MediaItem> media = new ArrayList<>();
        if (req.mediaIds() != null && !req.mediaIds().isEmpty()) {
            for (String mediaId : req.mediaIds()) {
                Long id = parseMediaId(mediaId);
                if (id != null) {
                    PostMediaEntity entity = mediaMapper.selectById(id);
                    if (entity != null) {
                        media.add(mediaAssembler.toDto(entity, true));
                    }
                }
            }
        }
        return new PostDetail(
                post.getId(),
                post.getType(),
                post.getLeafCategoryId(),
                post.getL2CategoryId(),
                post.getTitle(),
                post.getDescription(),
                req.attributes(),
                post.getLng(),
                post.getLat(),
                post.getAddress(),
                media,
                maskContact(req.contactValue()),
                post.getCompletenessLevel(),
                post.getStatus(),
                post.getExpireAt().toInstant(ZoneOffset.UTC),
                post.getVersion());
    }

    /**
     * 序列化 attributes 为 template_values JSON；null 时返回 null。
     */
    private String toJson(Map<String, Object> attributes) {
        if (attributes == null) {
            return null;
        }
        try {
            return objectMapper.writeValueAsString(attributes);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * 序列化三条件为 completeness_conditions JSON。
     */
    private String conditionsJson(PrecheckResult.Derived derived) {
        try {
            return objectMapper.writeValueAsString(Map.of(
                    "required_full", derived.requiredFull(),
                    "address_precise", derived.addressPrecise(),
                    "leaf_matched", derived.leafMatched()));
        } catch (Exception e) {
            return "{}";
        }
    }

    /**
     * 脱敏联系方式（完整值只由 /posts/{id}/contact 返回）。
     */
    private String maskContact(String value) {
        if (value == null || value.length() <= 7) {
            return value;
        }
        return value.substring(0, 3) + "****" + value.substring(value.length() - 4);
    }

    /**
     * 解析 media_id 字符串为 Long；非数字返回 null。
     */
    private Long parseMediaId(String mediaId) {
        try {
            return Long.valueOf(mediaId);
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
