package com.s2s.server.common.constants;

/**
 * ai 域 NFR 常量（B2-4；T2 AI 智能发布）。
 *
 * <p>职责：承载 AI 智能发布的**配额分层阈值**与上游调用超时。供 ai 域 service / 配额闸
 * 引用，禁在业务代码写死数字（编码规范红线「不复制字面量」）。</p>
 *
 * <p>出处：PRD §5.8 / §5.9 / §5.10「AI 配额二维分层（实名状态 × 完整度档）」、
 * PRD §2302 T2 接口表。配额档位来源（客户端传当前草稿档）见《决策登记表》
 * 2026-10-14 裁定。双端口径：Dart 侧 {@code lib/nfr_constants.dart} 的 {@code NfrAi}
 * 镜像（前端拼「每日额度 N 次」文案引用），改动须双端同步。</p>
 */
public final class NfrAi {

    /**
     * 工具类：禁止实例化。
     */
    private NfrAi() {
        throw new AssertionError("NfrAi 是常量类，不可实例化");
    }

    /**
     * 每日 AI 配额：实名 + 🟢 完整档（次/日）。PRD §5.8 / §5.10。
     */
    public static final int QUOTA_VERIFIED_GREEN = 20;

    /**
     * 每日 AI 配额：实名 + 🟡 完整档（次/日）。PRD §5.8 / §5.10。
     */
    public static final int QUOTA_VERIFIED_YELLOW = 10;

    /**
     * 每日 AI 配额：未实名或 🔴 完整档（次/日）。PRD §5.8 / §5.10。
     */
    public static final int QUOTA_UNVERIFIED_OR_RED = 3;

    /**
     * 高敏类目在基础配额上的加量（次/日）。PRD §5.8「高敏类目额外 +10 次」。
     */
    public static final int QUOTA_SENSITIVE_BONUS = 10;

    /**
     * 上游大模型调用超时（秒）。
     *
     * <p><b>实现默认值</b>（PRD 未定义具体秒数）：取 10s —— 客户端「解析中」骨架屏在
     * 5s 后改文案为「稍等，马上好」（{@code kParsingSlowSeconds}），故上游容忍到 10s
     * 仍属可接受等待；超时即回 {@code 50301}，客户端保留已输入内容。</p>
     */
    public static final int UPSTREAM_TIMEOUT_SECONDS = 10;

    /**
     * 上游大模型单次生成的输出 token 上限。
     *
     * <p><b>实现默认值</b>（PRD 未定义）：产物是一段小 JSON（标题/类目/价格/单位/模板字段），
     * 512 token 对中文已绰绰有余；设上限只为封住「模型失控长输出」的时延与费用，不改变
     * Step 4 逆向比对口径（越界字段照样被拒）。</p>
     */
    public static final int UPSTREAM_MAX_TOKENS = 512;

    /**
     * 费用上限：单用户每自然日（微元；1 元 = 1,000,000 微元）。
     *
     * <p><b>来源</b>：《决策登记表》2026-10-17 用户裁定「AI 调用费用：单用户每日低于
     * 1 元，每月低于 10 元」。单位取微元（long）以避免浮点误差；上限判定为「已达即拒」，
     * 故实际单日费用 &lt; 1 元（最后一次调用可能带来极小溢出，量级为分）。</p>
     */
    public static final long COST_DAILY_LIMIT_MICROYUAN = 1_000_000L;

    /**
     * 费用上限：单用户每自然月（微元）。
     *
     * <p>来源同 {@link #COST_DAILY_LIMIT_MICROYUAN}；按自然月（Asia/Shanghai）滚动，
     * 次月 1 日 00:00 重置。</p>
     */
    public static final long COST_MONTHLY_LIMIT_MICROYUAN = 10_000_000L;

    /**
     * 文本档（{@code qwen-plus}，华北2·北京、输入 ≤128K）输入单价（微元/千 token）。
     *
     * <p>官方价：0.8 元/百万 token（2026-10-13 价格页）。思考模式输出价更高，但本链路
     * 不开启思考模式，故按非思考价计。</p>
     */
    public static final long PRICE_TEXT_INPUT_MICROYUAN_PER_1K = 800L;

    /**
     * 文本档输出单价（微元/千 token）：2 元/百万 token（官方价）。
     */
    public static final long PRICE_TEXT_OUTPUT_MICROYUAN_PER_1K = 2_000L;

    /**
     * 多模态档（{@code qwen3.8-omni-flash}）文本/图片输入单价（微元/千 token）。
     *
     * <p>取官方 omni 档公开价 1.5 元/百万 token（华北2·北京，文本/图片/视频同价）。
     * 非实时档未单列更低价格，故按官方可查价<b>保守计</b>：高估只会让费用闸更早触发。</p>
     */
    public static final long PRICE_OMNI_INPUT_MICROYUAN_PER_1K = 1_500L;

    /**
     * 多模态档输出单价（微元/千 token）：4.5 元/百万 token（官方 omni 档公开价）。
     */
    public static final long PRICE_OMNI_OUTPUT_MICROYUAN_PER_1K = 4_500L;

    /**
     * 音频输入单价（微元/千 token）：6 元/百万 token。
     *
     * <p>转写复用 omni 档；官方对音频输入单独计价（realtime 档 6 元/百万），非实时档
     * 未单列，故<b>按较高的音频价保守计</b>——高估只会让费用闸更早触发，不会漏闸。</p>
     */
    public static final long PRICE_AUDIO_INPUT_MICROYUAN_PER_1K = 6_000L;

    /**
     * 上游未返回 {@code usage} 时的单次兜底计费（微元）：0.1 元。
     *
     * <p>宁可高估也不放行未计量调用：响应缺 usage 属上游异常，按固定值记账可防
     * 「因字段缺失而绕过费用上限」。</p>
     */
    public static final long COST_FALLBACK_PER_CALL_MICROYUAN = 100_000L;

    /**
     * AI 入参图片的目标宽度上限（像素，等比缩放）。
     *
     * <p><b>为什么缩</b>：上游多模态要先从 OSS 下载图片再编码，耗时随像素量上升；而带图
     * 链路受「后端读超时 {@link #UPSTREAM_TIMEOUT_SECONDS} 秒 + 客户端读取超时收紧档
     * {@code NfrNetwork.aiParseReadTimeoutSec}」双重约束。2026-10-17 实测同一张图
     * {@code reasoning_effort=none} 档仍为 6.3s，超客户端 5s 线 ⇒ 给上游传等比缩放的
     * 展示图副本。缩得越狠越快，但图内小字（价格/品牌）识别精度随之下降，故取 1024 折中；
     * 真机验收须同时核对识别质量（识别退化则向上调）。</p>
     *
     * <p>仅对图片生效：音频转写走原对象、不加任何图片处理参数（见 {@code MediaService}
     * 的 AI 只读签名）。</p>
     */
    public static final int AI_INPUT_IMAGE_WIDTH_PX = 1024;
}
