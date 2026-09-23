package com.s2s.server.post;

import com.s2s.server.post.dto.PostDraft;
import com.s2s.server.post.dto.PrecheckResult;
import java.util.List;
import org.springframework.stereotype.Service;

/**
 * 发布预检服务（[125]；R3 {@code POST /posts/precheck}，不落库）。
 *
 * <p>职责：提前暴露阻断项，校验项与 {@code POST /posts} 完全一致但不写库；
 * 通过时 {@code passed=true}，发现问题仍返回 200 + code=0，由 {@code blocks[]}
 * 一次性列出全部阻断项。</p>
 */
@Service
public class PrecheckService {

    private final PostValidator validator;

    /**
     * 构造预检服务。
     *
     * @param validator 发布校验组件
     */
    public PrecheckService(PostValidator validator) {
        this.validator = validator;
    }

    /**
     * 执行发布前置校验（不落库）。
     *
     * @param draft  发布草稿（半成品，字段可空）
     * @param userId 当前用户 ID
     * @return {@link PrecheckResult}（passed + blocks + derived）
     */
    public PrecheckResult precheck(PostDraft draft, Long userId) {
        List<PrecheckResult.Block> blocks = validator.collectBlocks(
                userId, draft.leafCategoryId(), draft.title(), draft.description(), draft.mediaIds());
        PrecheckResult.Derived derived = validator.computeDerived(
                draft.leafCategoryId(), draft.attributes(), draft.addressPrecise());
        return new PrecheckResult(blocks.isEmpty(), blocks, completenessLevel(derived), derived);
    }

    /**
     * 由三条件达成数映射完整度档位（3→2 / 2→1 / else→0）。
     */
    private Integer completenessLevel(PrecheckResult.Derived derived) {
        int count = (derived.requiredFull() ? 1 : 0)
                + (derived.addressPrecise() ? 1 : 0)
                + (derived.leafMatched() ? 1 : 0);
        if (count == 3) {
            return 2;
        }
        if (count == 2) {
            return 1;
        }
        return 0;
    }
}
