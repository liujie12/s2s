package com.s2s.server.cert.dto;

import java.time.LocalDateTime;

/**
 * 资质快照（cert 域对 post 域暴露的只读视图，用于帖级声明的冻结快照与展示状态判定）。
 *
 * <p>跨域只传本记录、不传实体：post 域不需要 {@code user_id}/{@code ocr_image_ref} 等
 * 内部列，实体外泄会让域边界形同虚设（编码规范 §4.2）。</p>
 *
 * @param certId     资质 ID（可空：凭证被删除后声明行的 {@code cert_id} 会置空）
 * @param certType   认证类型（{@code personal_qualification/enterprise/vehicle}）
 * @param certName   证书名称（可空）
 * @param expireType 有效期类型（{@code dated}/{@code permanent}）
 * @param expireAt   到期时间（长期有效为 {@code null}）
 * @param status     当前状态（{@code approved/expired}；历史行可能为 {@code pending/rejected}）
 */
public record CertSnapshot(
        Long certId,
        String certType,
        String certName,
        String expireType,
        LocalDateTime expireAt,
        String status) {
}
