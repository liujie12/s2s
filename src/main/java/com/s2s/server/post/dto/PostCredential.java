package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 帖级凭证声明块（对应 openapi {@code PostCredential}；一帖多证后为 {@code credentials[]} 的一项）。
 *
 * <p>只展示证名：主行字段取自写入时的冻结快照（永不改写），{@code state} 为读取时按
 * 凭证当前状态计算的实时值。归属行文案「由发布者提供，平台未核验」由客户端按本对象
 * 固定渲染，不依赖任何状态。</p>
 *
 * @param certId   资质档案 ID（编辑态回显勾选用；凭证被删除后历史行可为 {@code null}）
 * @param certName 证名快照（可空串；历史行为空）
 * @param state    展示状态（{@code valid}；非有效项在组装阶段已剔除）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostCredential(
        Long certId,
        String certName,
        String state) {
}
