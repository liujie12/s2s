package com.s2s.server.contact;

import com.s2s.server.common.constants.NfrApi;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.contact.dto.FavoriteItem;
import com.s2s.server.contact.dto.FavoriteResult;
import com.s2s.server.contact.dto.FavoritesResponse;
import com.s2s.server.contact.mapper.FavoriteMapper;
import com.s2s.server.post.PostQueryService;
import com.s2s.server.post.PostStatus;
import com.s2s.server.post.dto.MediaItem;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.springframework.stereotype.Service;

import static com.s2s.server.common.jdbc.JdbcRowValues.toInstant;
import static com.s2s.server.common.jdbc.JdbcRowValues.toInteger;
import static com.s2s.server.common.jdbc.JdbcRowValues.toLong;

/**
 * 收藏域服务（[B2-11]；openapi {@code POST/DELETE /posts/{id}/favorite}、{@code GET /favorites}；
 * PRD §8.3.2/§8.6/§8.7）。
 *
 * <p><b>域归属 = contact</b>：架构文档 §3（R9）把「收藏」列入 contact 职责、表→域映射把
 * {@code favorite} 归 contact；openapi 原 {@code x-domain: post} 为笔误，2026-10-11 裁定更正。</p>
 *
 * <p><b>跨域协作</b>：封面媒体需按「他人视角」组装，按架构文档 §3「功能域互相调用走对方的
 * service 接口」，经 {@link PostQueryService#coverMediaByPost} 取值，不直接注入 post 的
 * mapper/assembler（避免对方自判视角、绕开唯一实现处）。</p>
 *
 * <p><b>口径</b>（2026-10-11 裁定 DEC-31）：列表按收藏时间倒序；不设收藏上限（分页翻取）；
 * {@code type} ∈ {@code resource}/{@code demand}/{@code all}（{@code all} 与缺省等价＝不筛选）。</p>
 */
@Service
public class FavoriteService {

    /** 收藏类型入参「全部」的线值（openapi {@code /favorites} 的 {@code type=all}）。 */
    private static final String TYPE_ALL = "all";

    /** 帖子供需态合法筛选值（openapi {@code PostTypeEnum}，范式同 post 域 {@code MapService}）。 */
    private static final Set<String> POST_TYPE_FILTERS = Set.of("resource", "demand");

    private final FavoriteMapper favoriteMapper;
    private final PostQueryService postQueryService;

    /**
     * 构造收藏域服务。
     *
     * @param favoriteMapper   收藏关系读写 Mapper（本域）
     * @param postQueryService post 域读服务（取封面，跨域 service 接口）
     */
    public FavoriteService(FavoriteMapper favoriteMapper, PostQueryService postQueryService) {
        this.favoriteMapper = favoriteMapper;
        this.postQueryService = postQueryService;
    }

    /**
     * 收藏帖子（幂等）。
     *
     * @param userId 当前登录用户 ID（调用方保证非 null）
     * @param postId 帖子 ID
     * @return {@link FavoriteResult}（恒 {@code favorited=true}）
     * @throws BizException {@code 41001} 帖子不存在
     */
    public FavoriteResult addFavorite(Long userId, Long postId) {
        if (favoriteMapper.countPostById(postId) == 0) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        favoriteMapper.upsertFavorite(userId, postId);
        return new FavoriteResult(true);
    }

    /**
     * 取消收藏（幂等软删）。
     *
     * <p>不校验帖子是否存在：取消是「把已有关系置删」的幂等操作，对不存在的帖子也返回成功，
     * 避免帖子被物删后用户无法清理本地星标态。</p>
     *
     * @param userId 当前登录用户 ID（调用方保证非 null）
     * @param postId 帖子 ID
     * @return {@link FavoriteResult}（恒 {@code favorited=false}）
     */
    public FavoriteResult removeFavorite(Long userId, Long postId) {
        favoriteMapper.softDeleteFavorite(userId, postId, LocalDateTime.now());
        return new FavoriteResult(false);
    }

    /**
     * 查我的收藏分页（收藏时间倒序）。
     *
     * @param userId    当前登录用户 ID（调用方保证非 null）
     * @param typeParam 类型筛选线值；{@code null} 或 {@code all} 表示全部，非法值抛 {@code 40001}
     * @param page      页码；{@code null} 或 &lt;1 取 1
     * @param pageSize  每页条数；{@code null} 取 {@link NfrApi#PAGE_SIZE_DEFAULT}，超上限按下限钳制
     * @return {@link FavoritesResponse}
     * @throws BizException {@code 40001} 类型参数不在白名单内
     */
    public FavoritesResponse list(Long userId, String typeParam, Integer page, Integer pageSize) {
        String typeWire = resolveType(typeParam);

        int resolvedPage = page == null || page < 1 ? 1 : page;
        // 上限钳制：page_size 无界会让 LIMIT 失去边界（单次请求可拉全表），契约声明 max 50。
        int resolvedPageSize = pageSize == null || pageSize < 1
                ? NfrApi.PAGE_SIZE_DEFAULT
                : Math.min(pageSize, NfrApi.PAGE_SIZE_MAX);

        long total = favoriteMapper.countByUser(userId, typeWire);
        List<Map<String, Object>> rows = favoriteMapper.selectPage(userId, typeWire,
                (resolvedPage - 1) * resolvedPageSize, resolvedPageSize);

        List<Long> postIds = new ArrayList<>(rows.size());
        for (Map<String, Object> row : rows) {
            postIds.add(toLong(row.get("post_id")));
        }
        // 收藏者非帖主 → isOwner=false：post 域只回 pass 媒体（视角分流唯一实现处在 post 域）
        Map<Long, MediaItem> covers = postQueryService.coverMediaByPost(postIds, false);

        List<FavoriteItem> items = new ArrayList<>(rows.size());
        for (Map<String, Object> row : rows) {
            Long postId = toLong(row.get("post_id"));
            items.add(new FavoriteItem(
                    postId,
                    (String) row.get("type"),
                    toInteger(row.get("leaf_category_id")),
                    toInteger(row.get("l2_category_id")),
                    (String) row.get("title"),
                    (BigDecimal) row.get("price"),
                    (String) row.get("price_unit"),
                    covers.get(postId),
                    toInteger(row.get("completeness_level")),
                    PostStatus.toApi((String) row.get("status"), toInteger(row.get("status_reason"))),
                    toInstant(row.get("created_at")),
                    toInstant(row.get("favorite_at"))));
        }
        return new FavoritesResponse(items, total, resolvedPage, resolvedPageSize);
    }

    /**
     * 解析收藏类型入参。
     *
     * @param typeParam 类型筛选线值
     * @return {@link String} 帖子供需态线值；{@code null} 表示不筛选
     * @throws BizException {@code 40001} 非空但不在 {@code resource}/{@code demand}/{@code all} 内
     */
    private String resolveType(String typeParam) {
        if (typeParam == null || TYPE_ALL.equals(typeParam)) {
            return null;
        }
        if (POST_TYPE_FILTERS.contains(typeParam)) {
            return typeParam;
        }
        throw BizException.of(ErrorCode.PARAM_INVALID);
    }
}
