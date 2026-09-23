package com.s2s.server.post;

import com.s2s.server.category.TemplateService;
import com.s2s.server.category.dto.TemplateDto;
import com.s2s.server.category.dto.TemplateFieldDto;
import com.s2s.server.category.entity.CategoryEntity;
import com.s2s.server.category.mapper.CategoryMapper;
import com.s2s.server.cert.CertService;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.moderation.SensitiveWordChecker;
import com.s2s.server.post.dto.PrecheckResult;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.springframework.stereotype.Component;

/**
 * 发布校验组件（[125]；KTD5 precheck 与 POST /posts 共用）。
 *
 * <p>职责：承载五条阻断项校验（敏感词/图片/类目禁发/高敏资质/未实名上限），
 * 以及完整度三条件预演算。precheck 收集全部阻断项入 {@code blocks[]}；
 * POST /posts 命中即抛对应 {@link BizException}。</p>
 */
@Component
public class PostValidator {

    private final SensitiveWordChecker sensitiveWordChecker;
    private final MediaService mediaService;
    private final CategoryMapper categoryMapper;
    private final CertService certService;
    private final TemplateService templateService;

    /**
     * 构造发布校验组件。
     */
    public PostValidator(SensitiveWordChecker sensitiveWordChecker,
            MediaService mediaService,
            CategoryMapper categoryMapper,
            CertService certService,
            TemplateService templateService) {
        this.sensitiveWordChecker = sensitiveWordChecker;
        this.mediaService = mediaService;
        this.categoryMapper = categoryMapper;
        this.certService = certService;
        this.templateService = templateService;
    }

    /**
     * 收集全部阻断项（不抛异常，供 precheck 一次性给全）。
     *
     * @return 阻断项列表；空表示无阻断
     */
    public List<PrecheckResult.Block> collectBlocks(Long userId, Integer leafCategoryId,
            String title, String description, List<String> mediaIds) {
        List<PrecheckResult.Block> blocks = new ArrayList<>();

        try {
            sensitiveWordChecker.check(title);
            if (description != null) {
                sensitiveWordChecker.check(description);
            }
        } catch (BizException e) {
            blocks.add(new PrecheckResult.Block(
                    ErrorCode.SENSITIVE_WORD.getCode(), ErrorCode.SENSITIVE_WORD.getMessage(), "title"));
        }

        if (mediaIds != null) {
            for (String mediaId : mediaIds) {
                try {
                    mediaService.ensureNotRejected(parseMediaId(mediaId));
                } catch (BizException e) {
                    blocks.add(new PrecheckResult.Block(
                            ErrorCode.IMAGE_REJECTED.getCode(), ErrorCode.IMAGE_REJECTED.getMessage(), "media_ids"));
                    break;
                }
            }
        }

        CategoryEntity leaf = categoryMapper.selectById(leafCategoryId);
        if (leaf != null) {
            if (leaf.getForbidden() != null && leaf.getForbidden() != 0) {
                blocks.add(new PrecheckResult.Block(
                        ErrorCode.CATEGORY_BANNED.getCode(), ErrorCode.CATEGORY_BANNED.getMessage(), "leaf_category_id"));
            } else if (leaf.getNeedCert() != null && !hasQualification(userId)) {
                blocks.add(new PrecheckResult.Block(
                        ErrorCode.QUALIFICATION_NEEDED.getCode(), ErrorCode.QUALIFICATION_NEEDED.getMessage(), "leaf_category_id"));
            }
        }

        // 40304 未实名上限：Batch1 开关关，不产生阻断（cert 域延后致全员 none）
        return blocks;
    }

    /**
     * 校验并抛第一个阻断项（供 POST /posts 用）。
     *
     * @throws BizException 命中第一个阻断项时抛出
     */
    public void validate(Long userId, Integer leafCategoryId, String title,
            String description, List<String> mediaIds) {
        List<PrecheckResult.Block> blocks =
                collectBlocks(userId, leafCategoryId, title, description, mediaIds);
        if (!blocks.isEmpty()) {
            throw BizException.of(errorCodeFor(blocks.get(0).code()));
        }
    }

    /**
     * 预演算完整度三条件（供 precheck derived 与落库 completeness_conditions）。
     */
    public PrecheckResult.Derived computeDerived(Integer leafCategoryId,
            Map<String, Object> attributes, Boolean addressPrecise) {
        return new PrecheckResult.Derived(
                isRequiredFull(leafCategoryId, attributes),
                Boolean.TRUE.equals(addressPrecise),
                isLeaf(leafCategoryId));
    }

    /**
     * 判断是否已实名认证（Batch1 cert 空壳恒 none → 无资质）。
     */
    private boolean hasQualification(Long userId) {
        return !CertService.REALNAME_STATUS_NONE.equals(certService.getRealnameStatus(userId));
    }

    /**
     * 判断模板必填字段是否全部有值。
     */
    private boolean isRequiredFull(Integer leafCategoryId, Map<String, Object> attributes) {
        TemplateDto template = templateService.getByLeaf(leafCategoryId);
        for (TemplateFieldDto field : template.getFields()) {
            if (Boolean.TRUE.equals(field.getRequired())) {
                Object value = attributes == null ? null : attributes.get(field.getKey());
                if (value == null || (value instanceof String s && s.isBlank())) {
                    return false;
                }
            }
        }
        return true;
    }

    /**
     * 判断 leaf_category_id 是否为合法叶子节点（level=3）。
     */
    private boolean isLeaf(Integer leafCategoryId) {
        CategoryEntity leaf = categoryMapper.selectById(leafCategoryId);
        return leaf != null && leaf.getLevel() != null && leaf.getLevel() == 3;
    }

    /**
     * 按错误码映射回 {@link ErrorCode}（仅 post 域阻断项的五种码）。
     */
    private ErrorCode errorCodeFor(int code) {
        if (code == ErrorCode.SENSITIVE_WORD.getCode()) {
            return ErrorCode.SENSITIVE_WORD;
        }
        if (code == ErrorCode.IMAGE_REJECTED.getCode()) {
            return ErrorCode.IMAGE_REJECTED;
        }
        if (code == ErrorCode.CATEGORY_BANNED.getCode()) {
            return ErrorCode.CATEGORY_BANNED;
        }
        if (code == ErrorCode.QUALIFICATION_NEEDED.getCode()) {
            return ErrorCode.QUALIFICATION_NEEDED;
        }
        return ErrorCode.PARAM_INVALID;
    }

    /**
     * 解析 media_id 字符串为 Long；非数字返回 null（由调用方判定）。
     */
    private Long parseMediaId(String mediaId) {
        try {
            return Long.valueOf(mediaId);
        } catch (NumberFormatException e) {
            return null;
        }
    }
}
