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

    /**
     * 结构化起终点字段类型（与 openapi {@code TemplateField.type} 枚举同源，KTD2）。
     *
     * <p>该类型的值不是字符串而是 {@code {origin,destination,...}} 对象；
     * 必填判定按「两端都带数值坐标」而不是「非空字符串」。</p>
     */
    private static final String FIELD_TYPE_ROUTE_PAIR = "route_pair";

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
     * 判断叶类目当前是否可用（存在且未被运营禁用）。
     *
     * <p>[B2-8] 克隆重发用：原帖分类被运营停用（{@code forbidden != 0}）时须让前端提示重选
     * （PRD §8.7「重发分类变动」）。判定归本组件（precheck/POST /posts 的类目口径已在此），
     * 避免 post 域另起一处读 {@code category} 表。</p>
     *
     * @param leafCategoryId 叶子类目 ID（可空）
     * @return boolean；类目存在且 {@code forbidden} 为空/0 时为 {@code true}
     */
    public boolean isLeafAvailable(Integer leafCategoryId) {
        if (leafCategoryId == null) {
            return false;
        }
        CategoryEntity leaf = categoryMapper.selectById(leafCategoryId);
        return leaf != null && (leaf.getForbidden() == null || leaf.getForbidden() == 0);
    }

    /**
     * 判断是否已实名认证（Batch1 cert 空壳恒 none → 无资质）。
     */
    private boolean hasQualification(Long userId) {
        return !CertService.REALNAME_STATUS_NONE.equals(certService.getRealnameStatus(userId));
    }

    /**
     * 判断模板必填字段是否全部有值。
     *
     * <p>按字段类型分流（KTD4）：{@code route_pair} 要求对象形态且两端都带
     * 数值坐标；历史字符串形态按已填放行（存量帖没有坐标，不能因此被拦）。
     * 其余类型维持「null 或空白字符串即缺失」。</p>
     */
    private boolean isRequiredFull(Integer leafCategoryId, Map<String, Object> attributes) {
        TemplateDto template = templateService.getByLeaf(leafCategoryId);
        for (TemplateFieldDto field : template.getFields()) {
            if (!Boolean.TRUE.equals(field.getRequired())) {
                continue;
            }
            Object value = attributes == null ? null : attributes.get(field.getKey());
            if (FIELD_TYPE_ROUTE_PAIR.equals(field.getType())) {
                if (!isRoutePairFilled(value)) {
                    return false;
                }
                continue;
            }
            if (value == null || (value instanceof String s && s.isBlank())) {
                return false;
            }
        }
        return true;
    }

    /**
     * 判断起终点字段是否已填（KTD4）。
     *
     * <p>对象形态要求 {@code origin}/{@code destination} 各含数值 {@code lng}/{@code lat}；
     * 字符串形态是历史数据，按已填放行。不做「对象非空即已填」的放宽 ——
     * 那会让只填了一半的路线通过服务端校验。</p>
     *
     * @param value attributes 中该字段的原始值
     * @return boolean；true 表示已填
     */
    private boolean isRoutePairFilled(Object value) {
        if (value instanceof String s) {
            return !s.isBlank();
        }
        if (!(value instanceof Map<?, ?> route)) {
            return false;
        }
        return hasCoordinate(route.get("origin")) && hasCoordinate(route.get("destination"));
    }

    /**
     * 判断单个地点是否带可用的数值坐标。
     *
     * @param place 地点对象（期望 {@code Map}）
     * @return boolean；{@code lng}/{@code lat} 都是数值且落在合法经纬度范围内时为
     *     true。字符串坐标、缺坐标、越界坐标都不算 —— 无效坐标建不了索引，也
     *     算不了距离，不能当作「已选到具体 POI」。
     */
    private boolean hasCoordinate(Object place) {
        if (!(place instanceof Map<?, ?> map)) {
            return false;
        }
        Object lng = map.get("lng");
        Object lat = map.get("lat");
        if (!(lng instanceof Number) || !(lat instanceof Number)) {
            return false;
        }
        double lngValue = ((Number) lng).doubleValue();
        double latValue = ((Number) lat).doubleValue();
        return lngValue >= -180 && lngValue <= 180
                && latValue >= -90 && latValue <= 90;
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
