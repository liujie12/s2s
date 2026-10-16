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
