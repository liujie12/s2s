package com.s2s.server.contact;

import com.s2s.server.contact.mapper.FavoriteMapper;
import org.springframework.stereotype.Service;

/**
 * 收藏只读查询服务（跨域读入口）。
 *
 * <p>职责：向 post 域提供「当前用户是否已收藏」与「按帖聚合收藏数」的只读能力，
 * 避免 post 域直接注入 contact 的 Mapper（架构 §3 跨域协作口径）。
 * 写路径仍在 {@link FavoriteService}。</p>
 */
@Service
public class FavoriteQueryService {

    private final FavoriteMapper favoriteMapper;

    /**
     * 构造收藏只读查询服务。
     *
     * @param favoriteMapper 收藏关系 Mapper（本域）
     */
    public FavoriteQueryService(FavoriteMapper favoriteMapper) {
        this.favoriteMapper = favoriteMapper;
    }

    /**
     * 判断某用户是否已有效收藏某帖子。
     *
     * @param userId 用户 ID（调用方保证非 null）
     * @param postId 帖子 ID
     * @return boolean {@code true}=已收藏且未软删
     */
    public boolean isFavorited(Long userId, Long postId) {
        return favoriteMapper.countActiveFavorite(userId, postId) > 0;
    }
}
