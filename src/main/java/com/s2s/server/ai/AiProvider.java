package com.s2s.server.ai;

/**
 * 大模型供应商抽象（B2-4；DEC-30 同族的「接口 + dry-run 实现」范式）。
 *
 * <p>职责：把「把 scope 交给大模型生成四件套」抽象为单一方法，使 {@code AiParseService}
 * 只依赖本接口、不感知具体供应商。换供应商或 dry-run 切真服务只改实现类一处。</p>
 *
 * <p><b>实现选型（2026-10-13 裁定）</b>：通义千问（阿里云百炼），生成式AI服务备案号
 * {@code ZheJiang-TongYiQianWen-20230901}（配套算法备案号
 * {@code 网信算备330110507206401230035号}）。图识别与语音识别（ASR）均在其备案覆盖内，
 * 与文本共用同一模型通道（{@code qwen-omni} 支持文本 + 图像 + 音频同框输入）。</p>
 *
 * <p><b>严格 Scope（PRD §5.10）</b>：实现方只负责 Step 3「生成」——prompt 必须限死
 * 「仅可使用 scope 中出现的实体，禁止编造新实体」。Step 4 逆向比对由
 * {@code AiParseService} 独立承担，<b>不信任本接口的产物</b>。</p>
 */
public interface AiProvider {

    /**
     * 调用大模型对 scope 做四件套生成。
     *
     * @param scopeJson     允许使用的字段集合（Step 2 产物，JSON 字符串），作为 prompt 上下文
     * @param systemPrompt  系统提示词（限死「仅用 scope 字段、禁止编造」）
     * @return {@link String} 模型返回的原始输出文本（JSON），<b>未校验</b>；由调用方做 Step 4 逆向比对
     * @throws IllegalStateException 上游模型服务不可用（由调用方映射为 {@code 50301}）
     */
    String generate(String scopeJson, String systemPrompt);
}
