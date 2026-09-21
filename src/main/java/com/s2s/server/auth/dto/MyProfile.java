package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import com.s2s.server.auth.entity.UserEntity;
import java.util.List;

/**
 * 本人资料（[123] U3；对应 openapi {@code MyProfile} schema，user 出参唯一类型之一）。
 *
 * <p>对外视图白名单（数据库设计文档 §3.1）：{@code id/nickname/avatar_url/realname_status/
 * qualification_badges[]}；本人视角额外附 {@code default_radius} 与 {@code phone_mask}。</p>
 *
 * <p>数据最小化红线（安全 §9.6）：{@code real_name_enc}/{@code id_card_hash} <b>禁止</b>
 * 出现在任何 API 响应中——本 DTO 是 {@link com.s2s.server.auth.entity.UserEntity} 的对外投影，
 * {@link com.s2s.server.auth.entity.UserEntity} 不得直接返回（详设 §5.1）。</p>
 *
 * @param id                  用户 ID
 * @param nickname            昵称
 * @param avatarUrl           头像 OSS 临时访问地址（可空）
 * @param realnameStatus      实名状态（{@code none/pending/passed/rejected}）
 * @param qualificationBadges 已通过的资质徽章标识列表
 * @param defaultRadius       默认搜索半径档（{@code 1/3/5/10/city}）
 * @param phoneMask           脱敏手机号（仅本人视角可见）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MyProfile(
        Long id,
        String nickname,
        String avatarUrl,
        String realnameStatus,
        List<String> qualificationBadges,
        String defaultRadius,
        String phoneMask) {

    /**
     * 从用户实体投影为本人资料 DTO（对外视图白名单唯一落点，KTD4）。
     *
     * <p>{@code UserEntity} 不得直接返回——本方法是 user 出参的唯一投影，承载白名单
     * 裁剪：只投影 {@code id/nickname/avatar_url/realname_status/qualification_badges}
     * + 本人可见 {@code default_radius/phone_mask}；{@code real_name_enc}/{@code id_card_hash}
     * 等敏感列<b>永不投影</b>（安全 §9.6）。{@code qualification_badges} Batch1 恒空
     * （无资质徽章）。</p>
     *
     * @param user 用户实体
     * @return {@link MyProfile} 本人资料
     */
    public static MyProfile from(UserEntity user) {
        return new MyProfile(
                user.getId(),
                user.getNickname(),
                user.getAvatarUrl(),
                user.getRealnameStatus(),
                List.of(),
                user.getDefaultRadius(),
                user.getPhoneMask());
    }
}
