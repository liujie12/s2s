package com.s2s.server.common.moderation;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;

/**
 * 敏感词检测接口（[123] U8；跨域内容审核抽象）。
 *
 * <p>职责：检测文本是否命中敏感词，命中抛 {@link BizException}({@code 40901})。
 * 消费方为 auth 域昵称（U8）与 post 域发布标题/描述（后续条目），故按详设 §1.3
 * 「共享逻辑下沉 common」抽象为接口；实现语义归 AI 域（{@code ai/package-info.java}
 * 明确「发布预检敏感词 40901 归本域语义」），Batch1 空包，本接口由桩实现承载
 * （见 {@link NoopSensitiveWordChecker}）。</p>
 *
 * <p>出处：详设 §5.1（昵称敏感词）、§5.4（发布敏感词）、ErrorCode 40901。</p>
 */
public interface SensitiveWordChecker {

    /**
     * 检测文本是否命中敏感词。
     *
     * @param text 待检测文本（如昵称）
     * @throws BizException 命中敏感词 → {@code 40901}
     */
    void check(String text);
}
