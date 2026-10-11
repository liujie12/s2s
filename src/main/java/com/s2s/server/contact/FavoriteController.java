package com.s2s.server.contact;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import com.s2s.server.contact.dto.FavoriteResult;
import com.s2s.server.contact.dto.FavoritesResponse;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 收藏域控制器（[B2-11]；openapi {@code POST/DELETE /posts/{id}/favorite}、
 * {@code GET /favorites}）。
 *
 * <p><b>域归属 = contact</b>：架构文档 §3（R9）把「收藏」列入 contact 职责；openapi 原
 * {@code x-domain: post} 为笔误，2026-10-11 裁定更正为 contact。</p>
 *
 * <p><b>强制登录态</b>：收藏是「谁收藏了什么」的强归属数据，未登录 → {@code 40101}
 * （范式同本域 {@code ContactController}）。用户标识只取登录态，不接受入参指定。</p>
 *
 * <p><b>路径优先级</b>：{@code /favorites} 为顶层资源，与 {@code /posts/{post_id}} 无前缀重合，
 * 不存在「字面段 vs 变量段」歧义（这正是 2026-10-11 裁定弃用 {@code /posts/favorites} 的原因）。</p>
 */
@RestController
public class FavoriteController {

    private final FavoriteService favoriteService;

    /**
     * 构造收藏域控制器。
     *
     * @param favoriteService 收藏域服务
     */
    public FavoriteController(FavoriteService favoriteService) {
        this.favoriteService = favoriteService;
    }

    /**
     * 收藏帖子。
     *
     * @param postId      帖子 ID
     * @param httpRequest 当前请求（取登录态）
     * @return {@link FavoriteResult}
     * @throws BizException {@code 40101} 未登录 / {@code 41001} 帖子不存在
     */
    @PostMapping("/posts/{post_id}/favorite")
    public FavoriteResult addFavorite(@PathVariable("post_id") Long postId,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return favoriteService.addFavorite(userId, postId);
    }

    /**
     * 取消收藏。
     *
     * @param postId      帖子 ID
     * @param httpRequest 当前请求（取登录态）
     * @return {@link FavoriteResult}
     * @throws BizException {@code 40101} 未登录
     */
    @DeleteMapping("/posts/{post_id}/favorite")
    public FavoriteResult removeFavorite(@PathVariable("post_id") Long postId,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return favoriteService.removeFavorite(userId, postId);
    }

    /**
     * 我的收藏列表（分页 + 类型筛选）。
     *
     * @param type        类型筛选（{@code resource}/{@code demand}/{@code all}，缺省全部）
     * @param page        页码（从 1 起，缺省 1）
     * @param pageSize    每页条数（缺省 {@code NfrApi.PAGE_SIZE_DEFAULT}）
     * @param httpRequest 当前请求（取登录态）
     * @return {@link FavoritesResponse}
     * @throws BizException {@code 40101} 未登录 / {@code 40001} 类型参数非法
     */
    @GetMapping("/favorites")
    public FavoritesResponse listFavorites(
            @RequestParam(required = false) String type,
            @RequestParam(required = false) Integer page,
            @RequestParam(name = "page_size", required = false) Integer pageSize,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return favoriteService.list(userId, type, page, pageSize);
    }

    /**
     * 取登录用户 ID，未登录抛 {@code 40101}（范式同 {@code ContactController}）。
     *
     * @param request 当前请求
     * @return {@link Long} 登录用户 ID
     * @throws BizException {@code 40101}
     */
    private Long requireUserId(HttpServletRequest request) {
        Long userId = AuthContext.currentUserId(request);
        if (userId == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        return userId;
    }
}
