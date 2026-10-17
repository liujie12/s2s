package com.s2s.server.post;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.baomidou.mybatisplus.core.conditions.update.UpdateWrapper;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.ai.AiQuotaGate;
import com.s2s.server.common.constants.NfrPost;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.geo.GridIdCalculator;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import com.s2s.server.post.dto.MediaItem;
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
    private final AiQuotaGate aiQuotaGate;

    /**
     * 构造发布服务。
     *
     * @param aiQuotaGate AI 配额闸（B2-4；ai_assisted 发布成功后扣 1 次）
     */
    public PostService(PostMapper postMapper,
            PostMediaMapper mediaMapper,
            CryptoFacade cryptoFacade,
            PostValidator validator,
            MediaAssembler mediaAssembler,
            ObjectMapper objectMapper,
            AiQuotaGate aiQuotaGate) {
        this.postMapper = postMapper;
        this.mediaMapper = mediaMapper;
        this.cryptoFacade = cryptoFacade;
        this.validator = validator;
        this.mediaAssembler = mediaAssembler;
        this.objectMapper = objectMapper;
        this.aiQuotaGate = aiQuotaGate;
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
        post.setPrice(req.price() == null ? null : BigDecimal.valueOf(req.price()));
        post.setPriceUnit(req.priceUnit());
        // `desc` 列是 NOT NULL 且无默认值：契约允许 description 缺省（AI 快速发布
        // 不采集描述），null 会被 MyBatis-Plus 从 INSERT 中省略 ⇒ 数据库报
        // "Field 'desc' doesn't have a default value"（2026-10-17 线上实证 50001）。
        // 故在此归一为空串，而不是放宽表结构。
        post.setDescription(req.description() == null ? "" : req.description());
        post.setTemplateValues(toJson(req.attributes()));
        post.setGridId(gridId);
        post.setLng(BigDecimal.valueOf(req.lng()));
        post.setLat(BigDecimal.valueOf(req.lat()));
        post.setAddress(req.address());
        post.setContactChannel(req.contactType());
        post.setContactValueEnc(new byte[0]);
        // [147] DEC-13：发布时由明文派生脱敏掩码落库（详情/联系中转页未拉取态展示用，
        // 不触调解密——明文即用户本次提交值，非密文回解）。
        post.setContactMask(maskContact(req.contactValue()));
        post.setKeyVersion(0);
        post.setCompletenessConditions(conditionsJson(derived));
        post.setStatus(STATUS_ACTIVE);
        post.setRestricted(0);
        post.setAiAssisted(Boolean.TRUE.equals(req.aiAssisted()));
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

        // [B2-4] AI 配额扣减点：仅 ai_assisted=true 的发布扣 1 次（PRD §5.9「仅确认发布才计 1 次」）
        if (Boolean.TRUE.equals(req.aiAssisted())) {
            aiQuotaGate.increment(userId, RateLimitKeys.today());
        }

        // 重查取 STORED 生成列（l2_category_id / completeness_level）
        PostEntity saved = postMapper.selectById(post.getId());
        return assemble(saved, req.attributes(), req.mediaIds());
    }

    /**
     * 变更帖子状态（[127]；openapi {@code PATCH /posts/{post_id}/status}、详设 §5.3.3）。
     *
     * <p><b>乐观锁强约束</b>：{@code version} 必带（缺失由 Bean Validation 拦成 40001，
     * 本方法不做兜底）；更新语句形态 {@code WHERE id=? AND user_id=? AND version=?}，
     * 影响 0 行 → {@code 40903}（编码规范 §4.9），客户端须重取详情后由用户决定，
     * 禁自动带新 version 重发。</p>
     *
     * <p><b>归属并入 WHERE 而非先查归属</b>：非本人与版本不符一律表现为 0 行 → 同一个
     * {@code 40903}，既不新造 403 口径（依据源只规定「0 行→40903」），也不按 id 泄露
     * 「该帖存在且属他人」。</p>
     *
     * <p><b>{@code version} 自增写进 SQL</b>：本工程未注册 MyBatis-Plus 乐观锁插件
     * （{@code OptimisticLockerInnerInterceptor} 未配置，实体 {@code @Version} 不自动生效），
     * 故显式 {@code version = version + 1}；它与 {@code WHERE version=?} 是一对，
     * 只写其一即乐观锁失效。</p>
     *
     * <p><b>动作语义</b>（openapi 枚举，均清空 {@code status_reason}——只有「进入非 active
     * 路径」才有归因）：
     * <ul>
     *   <li>{@code offline}：{@code → archived} 且 {@code status_reason=0}（用户主动下架，
     *       数据库设计 §7.2 路径 1 {@code user_archive}）；</li>
     *   <li>{@code republish}：{@code → active}，重算 {@code expire_at}（详设 §5.3.3 状态机）；</li>
     *   <li>{@code renew}：保持 {@code active}，顺延 {@code expire_at}。</li>
     * </ul>
     * </p>
     *
     * @param userId 当前登录用户 ID（归属约束）
     * @param postId 帖子 ID
     * @param req    变更入参（{@code action} + {@code version}）
     * @return {@link PostStatusResult} 变更后状态/到期时间/新版本号
     * @throws BizException {@code 40001}（动作非法）、{@code 40903}（0 行：版本不符或非本人）
     */
    @Transactional
    public PostStatusResult updateStatus(Long userId, Long postId, PostStatusUpdateRequest req) {
        if (!PostStatus.isValidAction(req.action())) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        LocalDateTime now = LocalDateTime.now();
        UpdateWrapper<PostEntity> update = new UpdateWrapper<>();
        update.eq("id", postId).eq("user_id", userId).eq("version", req.version());
        switch (req.action()) {
            case PostStatus.ACTION_OFFLINE -> update
                    .set("status", PostStatus.DB_ARCHIVED)
                    .set("status_reason", PostStatus.REASON_USER_ARCHIVE);
            case PostStatus.ACTION_REPUBLISH, PostStatus.ACTION_RENEW -> update
                    .set("status", PostStatus.DB_ACTIVE)
                    .set("status_reason", null)
                    .set("expire_at", now.plusDays(NfrPost.VALID_DAYS));
            default -> throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        update.set("status_changed_at", now);
        update.setSql("version = version + 1");

        int affected = postMapper.update(null, update);
        if (affected == 0) {
            throw BizException.of(ErrorCode.VERSION_CONFLICT);
        }
        // 重查返回权威值（version 由 SQL 自增，实体侧不猜）
        PostEntity updated = postMapper.selectById(postId);
        return new PostStatusResult(
                updated.getId(),
                PostStatus.toApi(updated.getStatus(), updated.getStatusReason()),
                updated.getExpireAt().toInstant(ZoneOffset.UTC),
                updated.getVersion());
    }

    /**
     * 编辑帖子内容（[B2-8]；openapi {@code PATCH /posts/{post_id}}；PRD §8.4 步骤 4「进发布页编辑态」）。
     *
     * <p><b>只对在架帖开放</b>：更新语句 {@code WHERE id=? AND user_id=? AND version=? AND
     * status='active'}——非本人/版本不符/行不存在/非在架<b>一律 0 行 → {@code 40903}</b>
     * （不区分成因，与 {@link #updateStatus} 同口径，不按 id 探测存在性）。</p>
     *
     * <p><b>重走发布校验与派生</b>：敏感词/图片/类目/资质经 {@link PostValidator}；重算
     * {@code grid_id} 与 {@code completeness_conditions}（{@code completeness_level} 是 STORED
     * 生成列，禁写由实体策略保证）。<b>不重置 {@code expire_at}</b>（仅重发重置）。</p>
     *
     * <p><b>联系方式安全收窄</b>：{@code contactValue} 为 {@code null}/空表示<b>保留原密文不改</b>
     * ——明文唯一出口是 {@code GET /posts/{id}/contact}（安全方案 §4.6 出口收敛），编辑接口既不
     * 回显也不要求重填。给了新值才重新加密（AAD 仍是 {@code post_id}，与发布一致）。</p>
     *
     * <p><b>媒体重设</b>：先解绑该帖原全部媒体，再按 {@code mediaIds} 重新关联（未被选中的旧媒体
     * 因此解除 {@code post_id}，回到孤儿清理轨道）。</p>
     *
     * @param userId 当前登录用户 ID（归属约束）
     * @param postId 帖子 ID
     * @param req    编辑载荷（含 {@code version}）
     * @return {@link PostDetail} 编辑后详情（必带新 {@code version}）
     * @throws BizException 阻断项（40901/40902/40303/40302）、{@code 40903}（0 行）
     */
    @Transactional
    public PostDetail updatePost(Long userId, Long postId, PostUpdateRequest req) {
        // 复用发布校验（敏感词/图片/类目禁发/高敏资质），命中即抛
        validator.validate(userId, req.leafCategoryId(), req.title(), req.description(), req.mediaIds());

        String gridId = GridIdCalculator.of(req.lng(), req.lat());
        PrecheckResult.Derived derived =
                validator.computeDerived(req.leafCategoryId(), req.attributes(), req.addressPrecise());

        UpdateWrapper<PostEntity> update = new UpdateWrapper<>();
        update.eq("id", postId).eq("user_id", userId).eq("version", req.version())
                .eq("status", PostStatus.DB_ACTIVE)
                .set("type", req.type())
                .set("leaf_category_id", req.leafCategoryId())
                .set("title", req.title())
                .set("price", req.price() == null ? null : BigDecimal.valueOf(req.price()))
                .set("price_unit", req.priceUnit())
                .set("template_values", toJson(req.attributes()))
                .set("grid_id", gridId)
                .set("lng", BigDecimal.valueOf(req.lng()))
                .set("lat", BigDecimal.valueOf(req.lat()))
                .set("address", req.address())
                .set("completeness_conditions", conditionsJson(derived));

        // PATCH 语义：description 为 null 表示「本次不改」，不能写空串覆盖原描述
        // （`desc` 列 NOT NULL，新建时已在 createPost 归一为空串）。
        if (req.description() != null) {
            update.set("`desc`", req.description());
        }

        if (req.contactType() != null) {
            update.set("contact_channel", req.contactType());
        }
        if (req.contactValue() != null && !req.contactValue().isBlank()) {
            CryptoFacade.EncryptResult enc =
                    cryptoFacade.encrypt(req.contactValue(), String.valueOf(postId));
            update.set("contact_value_enc", enc.ciphertext());
            update.set("key_version", enc.keyVersion());
            update.set("contact_mask", maskContact(req.contactValue()));
        }
        update.setSql("version = version + 1");

        int affected = postMapper.update(null, update);
        if (affected == 0) {
            throw BizException.of(ErrorCode.VERSION_CONFLICT);
        }
        reLinkMedia(userId, postId, req.mediaIds());

        PostEntity saved = postMapper.selectById(postId);
        return assemble(saved, req.attributes(), req.mediaIds());
    }

    /**
     * 克隆重发：读取原帖返回可编辑草稿（[B2-8]；openapi {@code POST /posts/{post_id}/repost}；PRD §8.4/§8.6）。
     *
     * <p><b>只读、不落库</b>：本方法不写任何行；前端拿到草稿后带入发布页编辑态，用户确认后走
     * {@code POST /posts} 落 {@code active}（有效期在发布时重置为默认 7 天）。</p>
     *
     * <p><b>可重发状态</b>：仅 API 状态为 {@code offline}/{@code expired}（PRD §8.3.1 稿侧
     * 「已下架 → 刷新重发」）；其他状态回 {@code 40001}。帖子不存在或非本人回 {@code 41001}
     * （两者不区分，避免按 id 探测存在性）。</p>
     *
     * <p><b>不回显明文联系方式</b>：只回 {@code contactType} + {@code contactMask}（脱敏）。</p>
     *
     * @param userId 当前登录用户 ID（归属约束）
     * @param postId 帖子 ID
     * @return {@link RepostDraft} 可编辑草稿载荷
     * @throws BizException {@code 41001}（不存在/非本人）、{@code 40001}（状态不可重发）
     */
    public RepostDraft repost(Long userId, Long postId) {
        PostEntity post = postMapper.selectById(postId);
        if (post == null || !post.getUserId().equals(userId)) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        String apiStatus = PostStatus.toApi(post.getStatus(), post.getStatusReason());
        if (!PostStatus.API_OFFLINE.equals(apiStatus) && !PostStatus.API_EXPIRED.equals(apiStatus)) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return new RepostDraft(
                post.getId(),
                post.getType(),
                post.getLeafCategoryId(),
                post.getTitle(),
                post.getPrice() == null ? null : post.getPrice().doubleValue(),
                post.getPriceUnit(),
                post.getDescription(),
                fromJson(post.getTemplateValues()),
                post.getLng() == null ? null : post.getLng().doubleValue(),
                post.getLat() == null ? null : post.getLat().doubleValue(),
                post.getAddress(),
                addressPreciseOf(post.getCompletenessConditions()),
                mediaIdsOfPost(postId),
                post.getContactChannel(),
                post.getContactMask(),
                validator.isLeafAvailable(post.getLeafCategoryId()));
    }

    /**
     * 重设帖子媒体关联：先解绑原全部媒体，再按新列表重新关联（[B2-8] 编辑用）。
     *
     * @param userId   当前用户 ID（归属校验）
     * @param postId   帖子 ID
     * @param mediaIds 新媒体 ID 列表（可空 = 全部解绑）
     */
    private void reLinkMedia(Long userId, Long postId, List<String> mediaIds) {
        mediaMapper.update(null, new UpdateWrapper<PostMediaEntity>()
                .eq("post_id", postId).set("post_id", null));
        linkMedia(userId, postId, mediaIds);
    }

    /**
     * 取帖子已关联的媒体 ID 列表（[B2-8] 克隆重发用）。
     *
     * @param postId 帖子 ID
     * @return {@link List} media_id 字符串列表（契约中 media_id 为 string）
     */
    private List<String> mediaIdsOfPost(Long postId) {
        return mediaMapper.selectList(new QueryWrapper<PostMediaEntity>().eq("post_id", postId))
                .stream()
                .map(media -> String.valueOf(media.getId()))
                .toList();
    }

    /**
     * 反序列化 {@code template_values} JSON 为动态属性 Map（[B2-8]）。
     *
     * @param json 库内 JSON 文本（可空）
     * @return {@link Map} 属性；空/解析失败返回空 Map（不吞为异常，草稿可缺省）
     */
    private Map<String, Object> fromJson(String json) {
        if (json == null || json.isBlank()) {
            return Map.of();
        }
        try {
            return objectMapper.readValue(json, new TypeReference<Map<String, Object>>() { });
        } catch (Exception e) {
            return Map.of();
        }
    }

    /**
     * 从 {@code completeness_conditions} JSON 取 {@code address_precise}（[B2-8] 克隆重发用）。
     *
     * <p>为什么不从 {@code address} 列推断：本轮发布不上送 {@code address}（门牌号走
     * {@code address_precise} 布尔），故 {@code address} 恒空；三条件 JSON 才是唯一真源。</p>
     *
     * @param conditionsJson 三条件 JSON（可空）
     * @return {@link Boolean} 是否精确到门牌；缺失/解析失败返回 {@code null}
     */
    private Boolean addressPreciseOf(String conditionsJson) {
        if (conditionsJson == null || conditionsJson.isBlank()) {
            return null;
        }
        try {
            Map<String, Object> map =
                    objectMapper.readValue(conditionsJson, new TypeReference<Map<String, Object>>() { });
            Object value = map.get("address_precise");
            return value instanceof Boolean b ? b : null;
        } catch (Exception e) {
            return null;
        }
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
     *
     * <p>入参取「属性 Map + 媒体 ID 列表」而非整个请求对象：发布（{@link PostCreateRequest}）与
     * 编辑（{@link PostUpdateRequest}）两个载荷类型不同但出参同构，取二者公共数据即可复用本方法
     * （避免为编辑再抄一份组装逻辑）。</p>
     *
     * @param post       帖子实体（含 STORED 生成列）
     * @param attributes 动态属性（回填 {@code PostDetail.attributes}）
     * @param mediaIds   本次关联的媒体 ID 列表（本人视角全量）
     * @return {@link PostDetail} 详情
     */
    private PostDetail assemble(PostEntity post, Map<String, Object> attributes,
            List<String> mediaIds) {
        List<MediaItem> media = new ArrayList<>();
        if (mediaIds != null && !mediaIds.isEmpty()) {
            for (String mediaId : mediaIds) {
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
                // categoryPath / distanceM / author：POST /posts 出参不填充，属 [127] 读接口范畴
                null,
                post.getTitle(),
                post.getPrice(),
                post.getPriceUnit(),
                post.getDescription(),
                attributes,
                post.getLng(),
                post.getLat(),
                post.getAddress(),
                null,
                media,
                post.getContactMask(),
                post.getCompletenessLevel(),
                PostStatus.toApi(post.getStatus(), post.getStatusReason()),
                post.getCreatedAt().toInstant(ZoneOffset.UTC),
                post.getExpireAt().toInstant(ZoneOffset.UTC),
                null,
                post.getVersion(),
                Boolean.TRUE.equals(post.getAiAssisted()));
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
