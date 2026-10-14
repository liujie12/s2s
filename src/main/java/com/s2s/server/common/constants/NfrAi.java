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
}
