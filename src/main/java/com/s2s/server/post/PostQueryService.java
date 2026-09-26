package com.s2s.server.post;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.category.CategoryService;
import com.s2s.server.common.config.SystemConfigService;
import com.s2s.server.common.constants.NfrApi;
import com.s2s.server.common.dto.AuthorBrief;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.post.dto.MediaItem;
import com.s2s.server.post.dto.MyPostItem;
import com.s2s.server.post.dto.MyPostsResponse;
import com.s2s.server.post.dto.PostDetail;
import com.s2s.server.post.entity.PostMediaEntity;
import com.s2s.server.post.mapper.PostMediaMapper;
import com.s2s.server.post.mapper.PostQueryMapper;
import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Service;

/**
 * post 域读服务（[127]；详设 §5.3.3 状态机段 + openapi {@code GET /posts/{id}}、
 * {@code GET /posts/mine}）。
 *
 * <p>职责：承载 post 域两个读接口——详情（含游客可读与 42907/40301 前置语义）与
 * 「我的发布」分页。写路径（发布、状态变更）在 {@link PostService}，
 * 读写在 service 层分流而非同域堆叠（[125] 只落发布链，[127] 只落读路径）。</p>
 *
 * <p><b>状态口径</b>：库内 {@code (status, status_reason)} → 对外 API 值的派生只在
 * {@link PostStatus} 完成，本类不写第二次映射。</p>
 */
@Service
public class PostQueryService {

    /** {@code system_config} 中未实名详情额度开关的键（数据库设计 §7.5）。 */
    private static final String DETAIL_QUOTA_ENABLED_KEY = "detail_quota_enabled";

    private final PostQueryMapper postQueryMapper;
    private final PostMediaMapper postMediaMapper;
    private final MediaAssembler mediaAssembler;
    private final CategoryService categoryService;
    private final SystemConfigService systemConfigService;
    private final ObjectMapper objectMapper;

    /**
     * 构造 post 读服务。
     *
     * @param postQueryMapper    读路径 Mapper（联表 / 批量聚合）
     * @param postMediaMapper    媒体 Mapper（详情与封面）
     * @param mediaAssembler     媒体视角分流组装器（禁在 service/controller 自行判视角）
     * @param categoryService    分类服务（类目面包屑）
     * @param systemConfigService 系统配置读取（详情额度开关）
     * @param objectMapper       JSON 解析器（{@code template_values} → attributes）
     */
    public PostQueryService(PostQueryMapper postQueryMapper,
            PostMediaMapper postMediaMapper,
            MediaAssembler mediaAssembler,
            CategoryService categoryService,
            SystemConfigService systemConfigService,
            ObjectMapper objectMapper) {
        this.postQueryMapper = postQueryMapper;
        this.postMediaMapper = postMediaMapper;
        this.mediaAssembler = mediaAssembler;
        this.categoryService = categoryService;
        this.systemConfigService = systemConfigService;
        this.objectMapper = objectMapper;
    }

    /**
     * 查帖子详情（未登录可读，限频由横切链的 42907 轨承载）。
     *
     * <p>判定顺序（详设 §5.3.3 / openapi 描述）：
     * <ol>
     *   <li>行不存在 → {@code 41001}（与「已下架」同码，不区分可避免按 id 探测存在性）；</li>
     *   <li>非本人且状态非 {@code active} → {@code 41001}（本人看自己的下架帖不受限）；</li>
     *   <li>非本人且已登录 → 未实名额度判定（Batch1 由 {@code detail_quota_enabled=off}
     *       短路放行）；</li>
     * </ol>
     * 游客限频（42907）不在本类：由 {@code @RateLimit({GUEST_DETAIL_DEV, GUEST_DETAIL_IP})}
     * 在 controller 声明、鉴权之后判定。</p>
     *
     * @param viewerId 访问者 ID；游客为 {@code null}
     * @param postId   帖子 ID
     * @return {@link PostDetail}
     * @throws BizException {@code 41001}（不存在 / 对他人不可见）
     */
    public PostDetail getDetail(Long viewerId, Long postId) {
        Map<String, Object> row = postQueryMapper.selectDetailRow(postId);
        if (row == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        Long ownerId = toLong(row.get("user_id"));
        boolean isOwner = viewerId != null && viewerId.equals(ownerId);
        String dbStatus = (String) row.get("status");

        if (!isOwner) {
            if (PostStatus.isGoneForOthers(dbStatus)) {
                throw BizException.of(ErrorCode.POST_GONE);
            }
            checkDetailQuota(viewerId);
        }

        Integer leafCategoryId = toInteger(row.get("leaf_category_id"));
        AuthorBrief author = new AuthorBrief(
                toLong(row.get("author_id")),
                (String) row.get("author_nickname"),
                (String) row.get("author_avatar_url"),
                (String) row.get("author_realname_status"),
                // qualification_badges：Batch1 资质源为 cert 空壳，恒空列表（AuthorBrief 注释）
                List.of());

        return new PostDetail(
                toLong(row.get("id")),
                (String) row.get("type"),
                leafCategoryId,
                toInteger(row.get("l2_category_id")),
                categoryService.categoryPath(leafCategoryId),
                (String) row.get("title"),
                (BigDecimal) row.get("price"),
                (String) row.get("price_unit"),
                (String) row.get("description"),
                parseAttributes((String) row.get("template_values")),
                (BigDecimal) row.get("lng"),
                (BigDecimal) row.get("lat"),
                (String) row.get("address"),
                // distanceM：详情接口无视野中心入参（openapi 未声明 lng/lat），恒 null
                null,
                assembleMedia(postId, isOwner),
                // contactMask：GET 详情恒 null（PostDetail 类注释给出红线依据）
                null,
                toInteger(row.get("completeness_level")),
                PostStatus.toApi(dbStatus, toInteger(row.get("status_reason"))),
                toInstant(row.get("created_at")),
                toInstant(row.get("expire_at")),
                author,
                toLong(row.get("version")));
    }

    /**
     * 查「我的发布」分页（本人视角，封面媒体下三态）。
     *
     * @param userId   当前登录用户 ID
     * @param apiStatus API 状态筛选值（{@code null} 表示全部）
     * @param page     页码（{@code null} 取 1，对齐 {@code MapService} 既有口径）
     * @param pageSize 每页条数（{@code null} 取 {@link NfrApi#PAGE_SIZE_DEFAULT}）
     * @return {@link MyPostsResponse}
     */
    public MyPostsResponse listMine(Long userId, String apiStatus, Integer page, Integer pageSize) {
        PostStatus.ApiStatusFilter filter = PostStatus.filterFor(apiStatus);
        List<String> dbStatuses = filter == null ? null : filter.dbStatuses();
        List<Integer> reasons = filter == null ? null : filter.reasons();
        boolean allowNullReason = filter != null && filter.allowNullReason();

        int resolvedPage = page == null || page < 1 ? 1 : page;
        // 上限钳制：page_size 无界会让 LIMIT 与后续 IN (postIds) 批量查询失去边界，
        // 单次请求可拉取全表（openapi 声明 max 50，此处兑现）。
        int resolvedPageSize = pageSize == null || pageSize < 1
                ? NfrApi.PAGE_SIZE_DEFAULT
                : Math.min(pageSize, NfrApi.PAGE_SIZE_MAX);

        long total = postQueryMapper.countMine(userId, dbStatuses, reasons, allowNullReason);
        List<Map<String, Object>> rows = postQueryMapper.selectMine(userId, dbStatuses, reasons,
                allowNullReason, (resolvedPage - 1) * resolvedPageSize, resolvedPageSize);

        List<Long> postIds = new ArrayList<>();
        for (Map<String, Object> row : rows) {
            postIds.add(toLong(row.get("id")));
        }
        Map<Long, MediaItem> covers = coverMediaByPost(postIds);
        Map<Long, Long> contactCounts = contactCountByPost(postIds);

        List<MyPostItem> items = new ArrayList<>(rows.size());
        for (Map<String, Object> row : rows) {
            Long id = toLong(row.get("id"));
            items.add(new MyPostItem(
                    id,
                    (String) row.get("type"),
                    toInteger(row.get("leaf_category_id")),
                    (String) row.get("title"),
                    covers.get(id),
                    toInteger(row.get("completeness_level")),
                    PostStatus.toApi((String) row.get("status"), toInteger(row.get("status_reason"))),
                    toInstant(row.get("created_at")),
                    toInstant(row.get("expire_at")),
                    // viewCount：Batch1 无数据源（浏览计数随 [129] 埋点落库），恒 null
                    null,
                    contactCounts.getOrDefault(id, 0L),
                    toLong(row.get("version"))));
        }
        return new MyPostsResponse(items, total, resolvedPage, resolvedPageSize);
    }

    /**
     * 未实名详情额度判定（详设 §5.3.4 的 {@code checkDetailQuota} 落点）。
     *
     * <p>Batch1：{@code detail_quota_enabled='off'} → 直接返回，不查用户、不计数
     * （开关 off 是 DDL 种子值，理由见数据库设计 §7.5）。</p>
     *
     * <p><b>开关为 on 时 fail-fast</b>：额度口径（计数键形态、窗口、存储介质）在依据源中
     * 未定义——详设 §3.4 的键表 11 行无该轨，库内亦无对应表，仅 PRD §12.3 给了
     * 「每日 3 条、第 4 条 40301」的结论。按红线「设计文档未覆盖的口径先问，禁自创口径」
     * 不在此处造键；改为抛异常，使「开关被打开但额度未实现」在打开配置的那一刻暴露，
     * 而不是静默放行（静默放行 = 额度无声失效且无人发现）。裁定后回填实现，
     * 见说明文档 §2.9。</p>
     *
     * @param viewerId 已登录访问者 ID（游客无实名态，不适用该额度）
     */
    private void checkDetailQuota(Long viewerId) {
        if (viewerId == null || !systemConfigService.isOn(DETAIL_QUOTA_ENABLED_KEY)) {
            return;
        }
        throw new IllegalStateException("detail_quota_enabled=on，但 40301 额度计数口径未定义"
                + "（详设 §3.4 键表无该轨、库内无对应表）——不得自创键，待裁定后实现；"
                + "见说明文档 §2.9 DEC-07");
    }

    /**
     * 组装详情媒体列表（视角分流交给 {@link MediaAssembler}）。
     *
     * @param postId  帖子 ID
     * @param isOwner 是否本人视角
     * @return {@link List} 媒体项；他人视角下非 pass 媒体已被组装器过滤为不出现在列表里
     */
    private List<MediaItem> assembleMedia(Long postId, boolean isOwner) {
        List<PostMediaEntity> medias = postMediaMapper.selectList(
                new QueryWrapper<PostMediaEntity>().eq("post_id", postId).orderByAsc("id"));
        List<MediaItem> items = new ArrayList<>(medias.size());
        for (PostMediaEntity media : medias) {
            MediaItem dto = mediaAssembler.toDto(media, isOwner);
            if (dto != null) {
                items.add(dto);
            }
        }
        return items;
    }

    /**
     * 批量取每帖封面媒体（每帖第一条媒体，本人视角三态）。
     *
     * @param postIds 当前页帖子 ID 列表
     * @return {@link Map} postId → 封面媒体；无媒体或该帖首条被过滤时为缺省（不放入）
     */
    private Map<Long, MediaItem> coverMediaByPost(List<Long> postIds) {
        if (postIds.isEmpty()) {
            return Map.of();
        }
        List<PostMediaEntity> medias = postMediaMapper.selectList(
                new QueryWrapper<PostMediaEntity>().in("post_id", postIds).orderByAsc("id"));
        Map<Long, MediaItem> covers = new LinkedHashMap<>();
        for (PostMediaEntity media : medias) {
            if (covers.containsKey(media.getPostId())) {
                continue;
            }
            MediaItem dto = mediaAssembler.toDto(media, true);
            if (dto != null) {
                covers.put(media.getPostId(), dto);
            }
        }
        return covers;
    }

    /**
     * 批量取每帖联系方式被查看次数（{@code contact_event} 聚合，[128] 起有数据）。
     *
     * @param postIds 当前页帖子 ID 列表
     * @return {@link Map} postId → 次数；无事件的帖子不出现在 map 里
     */
    private Map<Long, Long> contactCountByPost(List<Long> postIds) {
        if (postIds.isEmpty()) {
            return Map.of();
        }
        List<Map<String, Object>> rows = postQueryMapper.countContactEvents(postIds);
        Map<Long, Long> counts = new LinkedHashMap<>();
        for (Map<String, Object> row : rows) {
            counts.put(toLong(row.get("post_id")), toLong(row.get("cnt")));
        }
        return counts;
    }

    /**
     * 解析 {@code template_values} JSON 为 attributes。
     *
     * @param json 库内 JSON 字符串（可空）
     * @return {@link Map} 动态属性；空值返回空 map（契约层要求 object 类型）
     * @throws IllegalStateException JSON 破损时抛出——写入方受控，破损即缺陷，
     *         静默返回空 map 会让「属性整块丢失」看起来正常
     */
    private Map<String, Object> parseAttributes(String json) {
        if (json == null || json.isBlank()) {
            return Map.of();
        }
        try {
            return objectMapper.readValue(json, new TypeReference<Map<String, Object>>() {
            });
        } catch (Exception e) {
            throw new IllegalStateException("post.template_values 不是合法 JSON 对象: " + json, e);
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

    /**
     * 把 JDBC 取回的时间列转 UTC {@link Instant}（与 [125] 出参口径一致）。
     *
     * @param value 列值（{@code LocalDateTime} 或 null）
     * @return {@link Instant}；null 时返回 {@code null}
     */
    private Instant toInstant(Object value) {
        return value instanceof LocalDateTime dateTime ? dateTime.toInstant(ZoneOffset.UTC) : null;
    }
}
