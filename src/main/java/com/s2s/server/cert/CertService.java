package com.s2s.server.cert;

import org.springframework.stereotype.Service;

/**
 * 实名认证服务空壳（[123] U9；详设 §1.2「cert 域 Batch2，Batch1 仅留包与空 service」）。
 *
 * <p>职责：供 post 域查询用户实名状态（详设 §1.3 域间只调 service，{@code post.PostService}
 * 可调本 {@link CertService}、不可调 cert Mapper）。Batch1 实名核验（身份证 OCR + 二要素）
 * 整体延后 Batch2，故 {@link #getRealnameStatus} 恒返回 {@value #REALNAME_STATUS_NONE}，
 * 对应详设 §0.2 裁定「Batch1 全员 {@code realname_status='none'}」。</p>
 *
 * <p>消费点（Batch2 落地后启用）：post 域未实名发布上限 40304、详情额度 40301，均依赖
 * 本方法判断「是否已实名」，Batch1 由 {@code system_config} 开关短路。</p>
 */
@Service
public class CertService {

    /** 实名状态枚举值：未实名（{@code user.realname_status='none'}，Batch1 恒值）。 */
    public static final String REALNAME_STATUS_NONE = "none";

    /**
     * 查询用户实名状态（Batch1 空壳：恒未实名）。
     *
     * @param userId 用户 ID（Batch2 用于查真实实名核验结果，Batch1 未使用）
     * @return {@link String} 实名状态，Batch1 恒返回 {@value #REALNAME_STATUS_NONE}
     */
    public String getRealnameStatus(Long userId) {
        return REALNAME_STATUS_NONE;
    }
}
