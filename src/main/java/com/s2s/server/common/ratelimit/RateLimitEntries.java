package com.s2s.server.common.ratelimit;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.ratelimit.RateLimiter.RateLimitEntry;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;

/**
 * 「限频轨 → 计数条目」换算的<b>唯一实现处</b>（[122] U4 起内置于
 * {@code RateLimitInterceptor}，[128] 上浮为本类）。
 *
 * <p><b>为什么必须上浮</b>：contact 域的联系方式拉取是「四轨五重防护」的复合场景
 * （详设 §5.5.1 第 [2]–[4] 步的次序由业务决定，不能靠注解在链上统一执行），
 * 故 contact service 需直调 {@link RateLimiter}——若在此处照抄一份
 * 「轨 → 键 → 五元组」的映射，就会出现两处必须同改的分支判断（新增一条轨时漏改
 * 其中一处，表现为「注解声明了但没生效」的静默失效）。编码规范 §1.1 要求第 2 处
 * 消费前抽提，故上浮：声明式（拦截器）与命令式（业务直调）共用同一份换算。</p>
 *
 * <p><b>两条纪律在换算中的落地</b>（详设 §3.4）：
 * <ul>
 *   <li>纪律 1「账号级一律 user_id」——账号级轨在 userId 为 null（游客）时<b>跳过</b>，
 *       而不是用别的维度顶替；</li>
 *   <li>渠道级三轨（{@code SMS_PHONE}/{@code SMS_IP}/{@code LOGIN_FAIL}）的维度是手机号，
 *       在请求体里、本换算拿不到，故<b>显式拒绝</b>（快速失败而非静默放行，
 *       静默放行会让限频无声失效）。</li>
 * </ul>
 *
 * <p><b>设备头不可信</b>（详设 §3.4 特殊性 2 / KTD14）：{@code deviceId} 入键前经
 * {@link RateLimitKeys#isValidDeviceId(String)} 校验，不合法<b>只跳设备轨</b>
 * （IP 轨与账号轨照常计数），不拒绝整个请求——设备维是辅助维度，
 * 少一个维度比误拒正常请求更可接受。</p>
 */
public final class RateLimitEntries {

    /**
     * 工具类：禁止实例化。
     */
    private RateLimitEntries() {
        throw new AssertionError("RateLimitEntries 是工具类，不可实例化");
    }

    /**
     * 换算某一条限频轨在当前请求下应产生的计数条目集合。
     *
     * <p>返回空列表表示「该轨本次不生效」（游客的账号级轨、设备头非法的设备轨、
     * 已登录用户的游客轨），调用方据此继续处理其余轨，而非视为错误。</p>
     *
     * @param track      限频轨标识（{@link RateLimitTrack}）
     * @param dimensions 本次请求的四个维度取值 + 自然日
     * @return {@link List} 该轨的计数条目（逐窗口一条；不生效时为空列表，
     *         非 {@code null}）
     * @throws IllegalStateException 传入渠道级三轨时抛出（维度在请求体里，
     *         须业务代码直调 {@link RateLimiter}，详设 §3.4 纪律 2）
     */
    public static List<RateLimitEntry> forTrack(RateLimitTrack track, RateLimitDimensions dimensions) {
        List<RateLimitEntry> entries = new ArrayList<>();
        RateLimitTrack.WindowRule[] rules = track.rules();
        switch (track) {
            case SMS_PHONE, SMS_IP, LOGIN_FAIL -> throw new IllegalStateException(
                    "渠道级轨 " + track + " 不能经本类换算（维度是手机号，请求体里拿不到），"
                            + "须业务代码直调 RateLimiter（详设 §3.4 纪律 2）");
            case CONTACT_UID -> {
                if (dimensions.userId() != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(RateLimiter.entry(
                                RateLimitKeys.contactUidDay(dimensions.userId(), dimensions.today()),
                                rule, dimensions.today()));
                    }
                }
            }
            case CONTACT_DEV -> {
                addDeviceEntries(entries, rules, dimensions.deviceId(), dimensions.deviceIdValid(),
                        dimensions.today(), DeviceKeyKind.CONTACT);
            }
            case CONTACT_IP -> {
                for (RateLimitTrack.WindowRule rule : rules) {
                    entries.add(RateLimiter.entry(
                            RateLimitKeys.contactIpDay(dimensions.ip(), dimensions.today()),
                            rule, dimensions.today()));
                }
            }
            case CONTACT_BURST -> {
                if (dimensions.userId() != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(RateLimiter.entry(
                                RateLimitKeys.contactBurstMinute(dimensions.userId()), rule,
                                dimensions.today()));
                    }
                }
            }
            case REPORT_UID -> {
                if (dimensions.userId() != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(RateLimiter.entry(
                                RateLimitKeys.reportUidDay(dimensions.userId(), dimensions.today()),
                                rule, dimensions.today()));
                    }
                }
            }
            case TRACK_UID -> {
                if (dimensions.userId() != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(RateLimiter.entry(
                                RateLimitKeys.trackUidMinute(dimensions.userId()), rule,
                                dimensions.today()));
                    }
                }
            }
            case GUEST_DETAIL_DEV -> {
                // 42907 轨：仅未登录时计数（鉴权后判定，链序保证）
                if (dimensions.userId() == null) {
                    addDeviceEntries(entries, rules, dimensions.deviceId(), dimensions.deviceIdValid(),
                            dimensions.today(), DeviceKeyKind.GUEST_DETAIL);
                }
            }
            case GUEST_DETAIL_IP -> {
                if (dimensions.userId() == null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(RateLimiter.entry(
                                RateLimitKeys.guestDetailIpDay(dimensions.ip(), dimensions.today()),
                                rule, dimensions.today()));
                    }
                }
            }
        }
        return entries;
    }

    /**
     * 设备维度键的归属轨枚举：两条设备轨的<b>键拼装方法不同</b>（联系轨与未登录详情轨），
     * 而「校验合法性 → 不合法跳过」的处理完全相同。用本枚举把差异收成一处，
     * 避免两个 case 分支各写一遍相同的判空逻辑。
     */
    private enum DeviceKeyKind {
        /** 行 5：联系方式拉取（{@code rl:contact:dev:...}）。 */
        CONTACT,
        /** 行 10：未登录详情浏览（{@code rl:guestdetail:dev:...}）。 */
        GUEST_DETAIL
    }

    /**
     * 按设备维度的键拼装方式追加条目（设备头非法时一条都不追加）。
     *
     * @param entries        输出列表（原地追加）
     * @param rules          该轨的窗口规则集合
     * @param deviceId       设备头原值（可能为 null）
     * @param deviceIdValid  {@link RateLimitKeys#isValidDeviceId(String)} 的预计算结果
     * @param today          自然日
     * @param kind           设备键的归属轨（决定用哪个键拼装方法）
     */
    private static void addDeviceEntries(List<RateLimitEntry> entries,
            RateLimitTrack.WindowRule[] rules, String deviceId, boolean deviceIdValid,
            LocalDate today, DeviceKeyKind kind) {
        if (!deviceIdValid) {
            // 设备头不合法 → 跳过设备轨（KTD14：防键空间污染，不拒绝请求）
            return;
        }
        for (RateLimitTrack.WindowRule rule : rules) {
            String key = kind == DeviceKeyKind.CONTACT
                    ? RateLimitKeys.contactDevDay(deviceId, today)
                    : RateLimitKeys.guestDetailDevDay(deviceId, today);
            entries.add(RateLimiter.entry(key, rule, today));
        }
    }

    /**
     * 一次请求的限频维度取值包（五元组）。
     *
     * <p>为什么打包：{@link #forTrack(RateLimitTrack, RateLimitDimensions)} 需要四个维度 +
     * 自然日共 5 个值，逐参数传递会让每个调用点都写成「五个位置参数连着传」的形态；
     * 且 {@code deviceIdValid} 是 {@code deviceId} 的派生值（只在 {@link #of} 里算一次），
     * 分开传会出现「传了 deviceId 却忘了传 valid 标记」的静默偏差。</p>
     *
     * @param userId        登录用户 ID；游客为 {@code null}
     * @param deviceId      设备头原值（{@code X-Device-Id}）；缺头为 {@code null}
     * @param deviceIdValid 设备头是否通过 UUID v4 校验（{@link #of} 派生）
     * @param ip            客户端 IP（永不 {@code null}，无代理头时为直连地址）
     * @param today         当前自然日（Asia/Shanghai）
     */
    public record RateLimitDimensions(Long userId, String deviceId, boolean deviceIdValid,
            String ip, LocalDate today) {

        /**
         * 由原始维度值构造（设备合法性自动派生，避免调用侧漏算）。
         *
         * @param userId   登录用户 ID；游客传 {@code null}
         * @param deviceId 设备头原值；缺头传 {@code null}
         * @param ip       客户端 IP（永不 null）
         * @param today    当前自然日
         * @return {@link RateLimitDimensions} 五元组（{@code deviceIdValid} 已算好）
         */
        public static RateLimitDimensions of(Long userId, String deviceId, String ip,
                LocalDate today) {
            return new RateLimitDimensions(userId, deviceId,
                    RateLimitKeys.isValidDeviceId(deviceId), ip, today);
        }
    }

    /**
     * 取自然日窗口键的 TTL 秒数（到次日零点 + 2h 缓冲）。
     *
     * <p>供非计数型键（如 {@code fz:contact:...} 熔断冻结标记）复用同一 TTL 口径：
     * 冻结标记与自然日计数键必须同时失效，否则会出现「计数已归零但用户仍被冻结」
     * 或反之的错位。</p>
     *
     * @param today 当前自然日（Asia/Shanghai）
     * @return long 键 TTL 秒数（≈26h）
     */
    public static long naturalDayKeyTtlSeconds(LocalDate today) {
        return RateLimitKeys.secondsUntilEndOfDay(today)
                + RateLimitThresholds.NATURAL_DAY_TTL_BUFFER_SECONDS;
    }
}
