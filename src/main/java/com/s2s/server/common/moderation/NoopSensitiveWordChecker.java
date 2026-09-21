package com.s2s.server.common.moderation;

import org.springframework.stereotype.Component;

/**
 * 敏感词检测桩实现（[123] U8；Batch1 占位）。
 *
 * <p>职责：Batch1 不接真实敏感词检测（AI 域空包，{@code ai/package-info.java}），
 * 本桩恒判「无敏感词」（{@link #check} 空实现）。AI 域敏感词检测落地后，以真实
 * {@link SensitiveWordChecker} 实现替换本 Bean（Spring 单实现注入，替换即切换）。</p>
 *
 * <p>为什么是桩而非删掉校验：昵称敏感词是 {@code 40901} 的消费点，接口 + 桩
 * 保证「调用点稳定 + 测试可 mock」，避免 AI 域落地时改 {@code UserService} 内部。</p>
 */
@Component
public class NoopSensitiveWordChecker implements SensitiveWordChecker {

    /**
     * 空实现：恒判无敏感词（Batch1 不接真实检测）。
     *
     * @param text 待检测文本（本桩不检测，仅保持接口契约）
     */
    @Override
    public void check(String text) {
        // TODO(AI 域落地后)：接入真实敏感词检测，命中抛 40901
    }
}
