package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 发布前置校验结果（[125]；对应 openapi {@code PrecheckResult}）。
 *
 * <p>校验通过时 {@code passed=true}；发现问题时仍返回 200 + code=0，由
 * {@code blocks[]} 一次性列出全部阻断项（不逐条打断用户）。</p>
 *
 * @param passed            是否无阻断项，可直接提交发布
 * @param blocks            全部阻断项一次性给全
 * @param completenessLevel 完整度档位（0/1/2）
 * @param derived           服务端预演算的派生值，供客户端提前展示完整度提示
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PrecheckResult(
        boolean passed,
        List<Block> blocks,
        Integer completenessLevel,
        Derived derived) {

    /**
     * 单个阻断项（对应一条错误码）。
     *
     * @param code    错误码（40901/40902/40303/40302/40304）
     * @param message 可直接呈现的中文提示
     * @param field   关联字段名，供客户端定位到具体表单项
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record Block(
            int code,
            String message,
            String field) {
    }

    /**
     * 三条件达成态预演算。
     *
     * @param requiredFull   模板必填字段是否全有值
     * @param addressPrecise 地址是否精确到门牌
     * @param leafMatched    叶子类目是否合法叶子节点
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record Derived(
            boolean requiredFull,
            boolean addressPrecise,
            boolean leafMatched) {
    }
}
