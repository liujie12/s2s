package com.s2s.server.map.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 作者摘要（[126]；对应 openapi {@code AuthorBrief}）。
 *
 * <p>严格遵循 {@code user} 对外视图白名单：仅 {@code id/nickname/avatar_url/
 * realname_status}，{@code phone_mask}/{@code real_name_enc}/{@code id_card_hash}
 * 不出现（数据最小化红线，安全 §9.6）。{@code qualification_badges} Batch1 恒空列表
 * （实名认证为 cert 空壳占位，无资质数据源）。</p>
 *
 * @param id                  用户 ID
 * @param nickname            昵称
 * @param avatarUrl           头像 OSS URL（可空）
 * @param realnameStatus      实名状态（none/pending/passed/rejected）
 * @param qualificationBadges 资质徽章（Batch1 恒空）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AuthorBrief(
        Long id,
        String nickname,
        String avatarUrl,
        String realnameStatus,
        List<String> qualificationBadges) {
}
