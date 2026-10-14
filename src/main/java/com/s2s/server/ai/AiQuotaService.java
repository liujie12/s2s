package com.s2s.server.ai;

import com.s2s.server.category.entity.CategoryEntity;
import com.s2s.server.category.mapper.CategoryMapper;
import com.s2s.server.cert.CertService;
import com.s2s.server.common.constants.NfrAi;
import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import com.s2s.server.ai.dto.AiQuota;
import java.time.Instant;
import java.time.LocalDate;
import org.springframework.stereotype.Service;

/**
 * AI 配额档位解析（B2-4；PRD §5.8/§5.10 二维配额表）。
 *
 * <p>职责：按「实名状态 × 完整度档」计算今日上限，并组装只读配额快照。档位来源
 * 由客户端传入<b>当前草稿</b>的 {@code completeness_level} 与 {@code leaf_category_id}
 * （《决策登记表》2026-10-14 裁定）；缺省视为最保守档（0=🔴）。</p>
 *
 * <p>档位映射（{@link NfrAi} 常量单源，禁写死数字）：</p>
 * <ul>
 *   <li>实名 + 🟢（level=2）→ {@link NfrAi#QUOTA_VERIFIED_GREEN}；</li>
 *   <li>实名 + 🟡（level=1）→ {@link NfrAi#QUOTA_VERIFIED_YELLOW}；</li>
 *   <li>未实名 或 🔴（level≤0/缺省）→ {@link NfrAi#QUOTA_UNVERIFIED_OR_RED}；</li>
 *   <li>高敏类目（{@code category.need_cert} 非空）→ 额外 + {@link NfrAi#QUOTA_SENSITIVE_BONUS}。</li>
 * </ul>
 */
@Service
public class AiQuotaService {

    /** 完整度档：🟢（对齐契约 completeness_level 2）。 */
    private static final int LEVEL_GREEN = 2;

    /** 完整度档：🟡（对齐契约 completeness_level 1）。 */
    private static final int LEVEL_YELLOW = 1;

    private final CertService certService;
    private final CategoryMapper categoryMapper;
    private final AiQuotaGate aiQuotaGate;

    /**
     * 构造配额档位服务。
     *
     * @param certService    实名状态查询（域间只调 service）
     * @param categoryMapper 分类 Mapper（高敏类目判定）
     * @param aiQuotaGate    AI 配额闸（读已用计数）
     */
    public AiQuotaService(CertService certService,
            CategoryMapper categoryMapper,
            AiQuotaGate aiQuotaGate) {
        this.certService = certService;
        this.categoryMapper = categoryMapper;
        this.aiQuotaGate = aiQuotaGate;
    }

    /**
     * 计算今日 AI 配额上限。
     *
     * @param userId            用户 ID
     * @param completenessLevel 当前草稿完整度档（0/1/2，可空）
     * @param leafCategoryId    当前叶子类目 ID（可空；用于高敏 +10）
     * @return int 今日上限（§5.8 二维配额表）
     */
    public int resolveLimit(Long userId, Integer completenessLevel, Integer leafCategoryId) {
        int base = baseQuota(userId, completenessLevel);
        return base + (isSensitive(leafCategoryId) ? NfrAi.QUOTA_SENSITIVE_BONUS : 0);
    }

    /**
     * 组装只读配额快照（已用 / 上限 / 重置时间）。
     *
     * @param userId 用户 ID
     * @param limit  今日上限（由 {@link #resolveLimit} 计算）
     * @return {@link AiQuota} 配额快照（{@code resetAt} = 次日 00:00 Asia/Shanghai）
     */
    public AiQuota snapshot(Long userId, int limit) {
        LocalDate today = RateLimitKeys.today();
        int used = aiQuotaGate.used(userId, today);
        Instant resetAt = today.plusDays(1)
                .atStartOfDay(RateLimitThresholds.ZONE)
                .toInstant();
        return new AiQuota(used, limit, resetAt);
    }

    /**
     * 基础额度：实名 × 完整度档（不含高敏加量）。
     *
     * @param userId            用户 ID
     * @param completenessLevel 完整度档（可空）
     * @return int 基础额度
     */
    private int baseQuota(Long userId, Integer completenessLevel) {
        if (!certService.isRealnamePassed(userId)) {
            // 未实名一律最低档（PRD §5.8「未实名或 🔴=3」）
            return NfrAi.QUOTA_UNVERIFIED_OR_RED;
        }
        int level = completenessLevel == null ? 0 : completenessLevel;
        if (level >= LEVEL_GREEN) {
            return NfrAi.QUOTA_VERIFIED_GREEN;
        }
        if (level == LEVEL_YELLOW) {
            return NfrAi.QUOTA_VERIFIED_YELLOW;
        }
        return NfrAi.QUOTA_UNVERIFIED_OR_RED;
    }

    /**
     * 是否高敏类目（{@code category.need_cert} 非空；PRD §2.4 需资质的叶子）。
     *
     * @param leafCategoryId 叶子类目 ID（可空）
     * @return boolean 高敏返回 {@code true}
     */
    private boolean isSensitive(Integer leafCategoryId) {
        if (leafCategoryId == null) {
            return false;
        }
        CategoryEntity leaf = categoryMapper.selectById(leafCategoryId);
        return leaf != null && leaf.getNeedCert() != null;
    }
}
