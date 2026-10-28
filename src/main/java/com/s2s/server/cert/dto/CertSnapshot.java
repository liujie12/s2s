package com.s2s.server.cert.dto;

/**
 * 资质快照（cert 域对 post 域暴露的只读视图，用于帖级声明的冻结快照与展示状态判定）。
 *
 * <p>跨域只传本记录、不传实体：post 域不需要 {@code user_id}/{@code ocr_image_ref} 等
 * 内部列，实体外泄会让域边界形同虚设（编码规范 §4.2）。资质已取消类型与有效期，
 * 快照只保留证名与状态。</p>
 *
 * @param certId   资质 ID（可空：凭证被删除后声明行的 {@code cert_id} 会置空）
 * @param certName 证书名称（可空）
 * @param status   当前状态（{@code approved}；历史行可能为 {@code pending/rejected}）
 */
public record CertSnapshot(
        Long certId,
        String certName,
        String status) {
}
