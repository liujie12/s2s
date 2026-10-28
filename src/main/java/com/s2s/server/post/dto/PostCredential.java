package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 帖级凭证声明块（对应 openapi {@code PostCredential}）。
 *
 * <p>主行字段全取自写入时的冻结快照（永不改写）；{@code state} 为读取时按凭证当前状态
 * 计算的实时值。归属行文案「由发布者提供，平台未核验」由客户端按本对象固定渲染，
 * 不依赖任何状态。</p>
 *
 * @param certType   证件类型快照
 * @param certName   证名快照（可空串；历史行为空）
 * @param expireType 有效期类型快照（{@code dated}/{@code permanent}）
 * @param expireAt   有效期快照（长期有效为 {@code null}）
 * @param state      展示状态（{@code valid/expired/revoked/deleted}）
 * @param declaredAt 声明时间（不参与排序）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostCredential(
        String certType,
        String certName,
        String expireType,
        Instant expireAt,
        String state,
        Instant declaredAt) {
}
