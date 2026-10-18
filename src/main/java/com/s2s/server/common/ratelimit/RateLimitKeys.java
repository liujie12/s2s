package com.s2s.server.common.ratelimit;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.web.UuidV4;
import java.time.LocalDate;
import java.time.YearMonth;
import java.time.format.DateTimeFormatter;

/**
 * 限频 Redis 键<b>唯一拼装处</b>（[122] U4；详设 §3.4 键表 11 行；编码规范 §1.2 唯一实现处清单）。
 *
 * <p><b>类型分维防串用</b>：不同维度的键拼装方法签名接收不同的维度参数（账号维收
 * {@code userId}、渠道维收 {@code phone}/{@code ip}、设备维收 {@code deviceId}），
 * 编译期即分维——调用方想把 userId 塞进 IP 轨的键里根本编不过，从类型系统层面
 * 杜绝「维度串用」这种高危缺陷（详设 §3.4 纪律 1：账号级一律 user_id）。
 *
 * <p>窗口键尾规则（KTD6）：
 * <ul>
 *   <li>{@code :1m} / {@code :1h} 轨 —— 滚动窗口，键尾无日期片，TTL = 窗口秒数；</li>
 *   <li>{@code :1d} 轨 —— <b>自然日</b>窗口，键尾内嵌 {@code yyyyMMdd} 日期片
 *       （时区固定 {@link RateLimitThresholds#ZONE} = Asia/Shanghai），
 *       TTL = 26h（比 24h 多 2h，防跨日边界残留 + 时钟漂移）。</li>
 * </ul>
 *
 * <p><b>设备头格式校验（KTD14）</b>：所有 deviceId 参数在入键前经
 * {@link #isValidDeviceId(String)} 校验，UUID v4 正则不匹配则视为缺头——
 * 调用方据此跳过设备轨（仅跳 dev 轨，IP 轨照常计数），防止恶意构造的设备 ID
 * 污染键空间（如超长串、控制字符、路径遍历字符等）。校验正则与前端
 * {@code X-Device-Id} 生成规则对齐（首次启动自生成 UUID）。
 *
 * <p>本类纯静态、无状态、纯函数式——同样输入永远产出同样键，便于测试断言。
 */
public final class RateLimitKeys {

    /** 限频计数键统一前缀。 */
    private static final String KEY_PREFIX = "rl:";

    /**
     * 熔断冻结标记键统一前缀。与计数键前缀（{@code rl:}）刻意区分：
     * 冻结标记是「判定结果」而非「计数器」，运维按前缀即可把两类键分开
     * 排查（如误封申诉时只删 {@code fz:*} 而不动计数）。
     */
    private static final String FREEZE_PREFIX = "fz:";

    /** 自然日窗口日期格式（yyyyMMdd）。 */
    private static final DateTimeFormatter DATE_FORMAT = DateTimeFormatter.ofPattern("yyyyMMdd");

    /** 自然月窗口格式（yyyyMM；AI 费用月累计键用）。 */
    private static final DateTimeFormatter MONTH_FORMAT = DateTimeFormatter.ofPattern("yyyyMM");

    /**
     * 工具类：禁止实例化。
     */
    private RateLimitKeys() {
        throw new AssertionError("RateLimitKeys 是工具类，不可实例化");
    }

    // ------------------------------------------------------------------
    // 行 1：短信发送（手机号维度）
    // ------------------------------------------------------------------

    /**
     * 行 1 · 短信·手机号·1 分钟窗键。
     *
     * @param phone 手机号（渠道级维度，未登录态可用）
     * @return {@link String} 键形 {@code rl:sms:phone:{phone}:1m}
     */
    public static String smsPhoneMinute(String phone) {
        return KEY_PREFIX + "sms:phone:" + phone + ":1m";
    }

    /**
     * 行 1 · 短信·手机号·1 小时窗键。
     *
     * @param phone 手机号
     * @return {@link String} 键形 {@code rl:sms:phone:{phone}:1h}
     */
    public static String smsPhoneHour(String phone) {
        return KEY_PREFIX + "sms:phone:" + phone + ":1h";
    }

    /**
     * 行 1 · 短信·手机号·1 自然日窗键（KTD6：键尾日期片 + 26h TTL）。
     *
     * @param phone 手机号
     * @param date  自然日（Asia/Shanghai 时区，由调用方传入，便于测试注入伪时钟）
     * @return {@link String} 键形 {@code rl:sms:phone:{phone}:1d:{yyyyMMdd}}
     */
    public static String smsPhoneDay(String phone, LocalDate date) {
        return KEY_PREFIX + "sms:phone:" + phone + ":1d:" + date.format(DATE_FORMAT);
    }

    // ------------------------------------------------------------------
    // 行 2：短信发送（IP 维度）
    // ------------------------------------------------------------------

    /**
     * 行 2 · 短信·IP·1 小时窗键。
     *
     * @param ip IP 地址（渠道级维度）
     * @return {@link String} 键形 {@code rl:sms:ip:{ip}:1h}
     */
    public static String smsIpHour(String ip) {
        return KEY_PREFIX + "sms:ip:" + ip + ":1h";
    }

    // ------------------------------------------------------------------
    // 行 3：登录失败锁定（手机号维度）
    // ------------------------------------------------------------------

    /**
     * 行 3 · 登录失败·手机号键（窗口 = 锁定时长 15min，不是自然日也不是滚动 1h）。
     *
     * @param phone 手机号
     * @return {@link String} 键形 {@code rl:login:fail:{phone}}
     */
    public static String loginFail(String phone) {
        return KEY_PREFIX + "login:fail:" + phone;
    }

    // ------------------------------------------------------------------
    // 行 4：联系方式拉取（账号维度）
    // ------------------------------------------------------------------

    /**
     * 行 4 · 联系·账号·1 自然日窗键（KTD6：键尾日期片）。
     *
     * @param userId 用户 ID（账号级维度，编译期分维：参数类型 Long，不是 String）
     * @param date   自然日
     * @return {@link String} 键形 {@code rl:contact:uid:{userId}:1d:{yyyyMMdd}}
     */
    public static String contactUidDay(Long userId, LocalDate date) {
        return KEY_PREFIX + "contact:uid:" + userId + ":1d:" + date.format(DATE_FORMAT);
    }

    // ------------------------------------------------------------------
    // 行 5：联系方式拉取（设备辅助维度）
    // ------------------------------------------------------------------

    /**
     * 行 5 · 联系·设备·1 自然日窗键（KTD6：键尾日期片）。
     *
     * @param deviceId 设备 ID（辅助维度；调用方应先用 {@link #isValidDeviceId(String)}
     *                 校验，不合法则跳过本轨，避免键空间污染——KTD14）
     * @param date     自然日
     * @return {@link String} 键形 {@code rl:contact:dev:{deviceId}:1d:{yyyyMMdd}}
     * @throws IllegalArgumentException deviceId 为 null 时抛出（调用方应先判空再跳过）
     */
    public static String contactDevDay(String deviceId, LocalDate date) {
        return KEY_PREFIX + "contact:dev:" + deviceId + ":1d:" + date.format(DATE_FORMAT);
    }

    // ------------------------------------------------------------------
    // 行 6：联系方式拉取（IP 渠道维度）
    // ------------------------------------------------------------------

    /**
     * 行 6 · 联系·IP·1 自然日窗键（KTD6：键尾日期片）。
     *
     * @param ip   IP 地址（渠道级维度）
     * @param date 自然日
     * @return {@link String} 键形 {@code rl:contact:ip:{ip}:1d:{yyyyMMdd}}
     */
    public static String contactIpDay(String ip, LocalDate date) {
        return KEY_PREFIX + "contact:ip:" + ip + ":1d:" + date.format(DATE_FORMAT);
    }

    // ------------------------------------------------------------------
    // 行 7：联系熔断（账号维度）
    // ------------------------------------------------------------------

    /**
     * 行 7 · 联系熔断·账号·1 分钟窗键。
     *
     * @param userId 用户 ID（账号级维度，Long 类型分维）
     * @return {@link String} 键形 {@code rl:contact:burst:{userId}:1m}
     */
    public static String contactBurstMinute(Long userId) {
        return KEY_PREFIX + "contact:burst:" + userId + ":1m";
    }

    /**
     * 行 7 · 联系熔断的<b>当日冻结标记</b>键（详设 §3.4 行 7「1min ≥10 次 → 当日冻结」、
     * 详设 §5.5.1 第 [2] 步「熔断冻结检查（{@code fz:contact:{userId}:{date}} 存在）→ 42903」）。
     *
     * <p>与 {@link #contactBurstMinute(Long)} 的分工：后者是 1 分钟滚动窗的<b>计数器</b>
     * （计数到阈值即刻触发 42903，但窗口滚过后计数自然归零）；本键是<b>判定结果</b>——
     * 一旦写入，当日余下时间一律 42903，不因 1 分钟窗滑出而复通。缺了本键，
     * 「当日冻结」会退化成「每分钟最多打 10 次」，与详设口径不符。</p>
     *
     * <p>键形 {@code fz:contact:{userId}:{yyyyMMdd}}，无 {@code :1d} 段——冻结标记的
     * 有效期由写入方按「到次日零点」设定，不在键名里重复表达窗口（详设原文键形即如此）。</p>
     *
     * @param userId 用户 ID（账号级维度，Long 类型分维）
     * @param date   冻结所属自然日（Asia/Shanghai，跨零点自动失效）
     * @return {@link String} 键形 {@code fz:contact:{userId}:{yyyyMMdd}}
     */
    public static String contactFreezeDay(Long userId, LocalDate date) {
        return FREEZE_PREFIX + "contact:" + userId + ":" + date.format(DATE_FORMAT);
    }

    // ------------------------------------------------------------------
    // 行 8：举报频次（账号维度）
    // ------------------------------------------------------------------

    /**
     * 行 8 · 举报·账号·1 自然日窗键（KTD6：键尾日期片）。
     *
     * @param userId 用户 ID（账号级维度，Long 类型分维）
     * @param date   自然日
     * @return {@link String} 键形 {@code rl:report:uid:{userId}:1d:{yyyyMMdd}}
     */
    public static String reportUidDay(Long userId, LocalDate date) {
        return KEY_PREFIX + "report:uid:" + userId + ":1d:" + date.format(DATE_FORMAT);
    }

    // ------------------------------------------------------------------
    // 行 9：埋点上报（账号维度）
    // ------------------------------------------------------------------

    /**
     * 行 9 · 埋点·账号·1 分钟窗键。
     *
     * @param userId 用户 ID（账号级维度，Long 类型分维）
     * @return {@link String} 键形 {@code rl:track:uid:{userId}:1m}
     */
    public static String trackUidMinute(Long userId) {
        return KEY_PREFIX + "track:uid:" + userId + ":1m";
    }

    // ------------------------------------------------------------------
    // 行 10：未登录详情浏览（设备维度）
    // ------------------------------------------------------------------

    /**
     * 行 10 · 未登录详情·设备·1 自然日窗键（KTD6：键尾日期片）。
     * 仅未登录请求使用本轨（AuthContext 为空时，调用方负责判断——链序保证在鉴权之后）。
     *
     * @param deviceId 设备 ID（KTD14：调用方先校验格式，不合法跳过本轨）
     * @param date     自然日
     * @return {@link String} 键形 {@code rl:guestdetail:dev:{deviceId}:1d:{yyyyMMdd}}
     */
    public static String guestDetailDevDay(String deviceId, LocalDate date) {
        return KEY_PREFIX + "guestdetail:dev:" + deviceId + ":1d:" + date.format(DATE_FORMAT);
    }

    // ------------------------------------------------------------------
    // 行 11：未登录详情浏览（IP 渠道维度）
    // ------------------------------------------------------------------

    /**
     * 行 11 · 未登录详情·IP·1 自然日窗键（KTD6：键尾日期片）。
     * 仅未登录请求使用本轨。
     *
     * @param ip   IP 地址（渠道级维度）
     * @param date 自然日
     * @return {@link String} 键形 {@code rl:guestdetail:ip:{ip}:1d:{yyyyMMdd}}
     */
    public static String guestDetailIpDay(String ip, LocalDate date) {
        return KEY_PREFIX + "guestdetail:ip:" + ip + ":1d:" + date.format(DATE_FORMAT);
    }

    // ------------------------------------------------------------------
    // 行 12：未实名详情额度（账号维度，额度闸专用，[149]）
    // ------------------------------------------------------------------

    /**
     * 未实名详情额度·账号·1 自然日窗键（[149]）。
     *
     * <p>与 §3.4 限频键表 11 行的区别：本键是「额度闸」而非「限频轨」——超限码
     * {@code 40301} 为 {@code needRetryAfter=false}（引导实名，非限频等待），故不由
     * {@link RateLimitTrack} 承载（该枚举绑定的是 needRetryAfter 码）；键拼装仍收口于
     * 本类（守「键拼装唯一处」，编码规范 §1.2），计数逻辑归 {@code post.DetailQuotaGate}。
     * 窗口语义同 {@code :1d} 轨：自然日 + 键尾日期片 + 26h TTL（KTD6）。</p>
     *
     * @param userId 用户 ID（账号级维度，Long 类型分维，编码规范 §4.7 账号级一律 user_id）
     * @param date   自然日（Asia/Shanghai，跨零点自动失效）
     * @return {@link String} 键形 {@code rl:detailquota:uid:{userId}:1d:{yyyyMMdd}}
     */
    public static String detailQuotaUidDay(Long userId, LocalDate date) {
        return KEY_PREFIX + "detailquota:uid:" + userId + ":1d:" + date.format(DATE_FORMAT);
    }

    // ------------------------------------------------------------------
    // 行 13：推送每日配额（账号维度，[B2-2]）
    // ------------------------------------------------------------------

    /**
     * 推送每日配额·账号·1 自然日窗键（[B2-2]）。
     *
     * <p>与 §3.4 限频键表 11 行的区别：本键是「服务端自限配额」而非「入站限流轨」——
     * 它限制的是**平台给用户发多少条**（PRD §6.14 ≤10 条/日），不是用户请求多快；
     * 超限不返回任何错误码（静默转站内通知），故不由 {@link RateLimitTrack} 承载。
     * 键拼装仍收口于本类（守「键拼装唯一处」，编码规范 §1.2），计数逻辑归
     * {@code notify.PushQuotaGate}。窗口语义同 {@code :1d} 轨：自然日 + 键尾日期片
     * + 26h TTL（KTD6）。</p>
     *
     * @param userId 接收者用户 ID（账号级维度，Long 类型分维，编码规范 §4.7）
     * @param date   自然日（Asia/Shanghai，跨零点自动失效）
     * @return {@link String} 键形 {@code rl:push:uid:{userId}:1d:{yyyyMMdd}}
     */
    public static String pushQuotaUidDay(Long userId, LocalDate date) {
        return KEY_PREFIX + "push:uid:" + userId + ":1d:" + date.format(DATE_FORMAT);
    }

    // ------------------------------------------------------------------
    // 行 14：AI 解析配额（账号维度，B2-4）
    // ------------------------------------------------------------------

    /**
     * AI 解析配额·账号·1 自然日窗键（B2-4）。
     *
     * <p>与 §3.4 限频键表 11 行的区别：本键是「配额闸」而非「限频轨」——超限码
     * {@code 42901} 为 {@code needRetryAfter=true}（携 {@code Retry-After}），
     * 「仅确认发布才计 1 次」（PRD §5.9），解析端点只读判定不计数。键拼装仍收口于
     * 本类（守「键拼装唯一处」，编码规范 §1.2），计数逻辑归 {@code ai.AiQuotaGate}。
     * 窗口语义同 {@code :1d} 轨：自然日 + 键尾日期片 + 26h TTL（KTD6）。</p>
     *
     * @param userId 用户 ID（账号级维度，Long 类型分维，编码规范 §4.7 账号级一律 user_id）
     * @param date   自然日（Asia/Shanghai，跨零点自动失效）
     * @return {@link String} 键形 {@code rl:aiquota:uid:{userId}:1d:{yyyyMMdd}}
     */
    public static String aiQuotaUidDay(Long userId, LocalDate date) {
        return KEY_PREFIX + "aiquota:uid:" + userId + ":1d:" + date.format(DATE_FORMAT);
    }

    /**
     * AI 调用费用·账号·自然日累计键（微元；B2-4 费用上限，2026-10-17 裁定）。
     *
     * <p>与配额键 {@link #aiQuotaUidDay} 语义不同：配额键计「确认发布次数」，本键计
     * 「实际 token 折算费用」。窗口同为自然日（Asia/Shanghai）+ 日期片，TTL 用
     * 26h（KTD6 同口径）。</p>
     *
     * @param userId 用户 ID（账号维度）
     * @param date   自然日
     * @return {@link String} 键形 {@code rl:aicost:uid:{userId}:1d:{yyyyMMdd}}
     */
    public static String aiCostUidDay(Long userId, LocalDate date) {
        return KEY_PREFIX + "aicost:uid:" + userId + ":1d:" + date.format(DATE_FORMAT);
    }

    /**
     * AI 调用费用·账号·自然月累计键（微元；2026-10-17 裁定「每月低于 10 元」）。
     *
     * <p>自然月语义：键尾内嵌 {@code yyyyMM}，次月 1 日 00:00 起用新键；TTL 覆盖到
     * 次月 1 日 + 2h 缓冲（与自然日键同思路，防跨月边界残留）。</p>
     *
     * @param userId 用户 ID（账号维度）
     * @param month  自然月（Asia/Shanghai）
     * @return {@link String} 键形 {@code rl:aicost:uid:{userId}:1mo:{yyyyMM}}
     */
    public static String aiCostUidMonth(Long userId, YearMonth month) {
        return KEY_PREFIX + "aicost:uid:" + userId + ":1mo:" + month.format(MONTH_FORMAT);
    }

    // ------------------------------------------------------------------
    // 行 15：微信登录（设备维 + IP 维，渠道级，B2-6a）
    // ------------------------------------------------------------------

    /**
     * 微信登录·设备维·1 小时窗键（B2-6a）。
     *
     * <p>依据《系统总体架构设计文档》§5.1.1 门禁①：微信自动注册必须有独立的
     * 设备维限频（阈值 ≤ 短信 IP 维 20/h），防止一台设备无限量注册。
     * 设备头入键前由 {@link #isValidDeviceId(String)} 校验（KTD14，调用方在
     * {@code RateLimitEntries} 里跳过非法值）。</p>
     *
     * @param deviceId 设备指纹（{@code X-Device-Id}，已通过 UUID v4 校验）
     * @return {@link String} 键形 {@code rl:wechat:dev:{deviceId}:1h}
     */
    public static String wechatLoginDevHour(String deviceId) {
        return KEY_PREFIX + "wechat:dev:" + deviceId + ":1h";
    }

    /**
     * 微信登录·IP 维·1 小时窗键（B2-6a）。
     *
     * <p>与设备维同阈值同窗口（架构 §5.1.1 门禁①）；IP 缺失时调用方应传直连地址，
     * 由 {@code ClientIp#of} 保证非空。</p>
     *
     * @param ip 客户端 IP（渠道级维度）
     * @return {@link String} 键形 {@code rl:wechat:ip:{ip}:1h}
     */
    public static String wechatLoginIpHour(String ip) {
        return KEY_PREFIX + "wechat:ip:" + ip + ":1h";
    }

    // ------------------------------------------------------------------
    // 设备 ID 格式校验（KTD14）
    // ------------------------------------------------------------------
    /**
     * 校验设备 ID 是否为合法 UUID v4 格式（KTD14：X-Device-Id 入键前格式校验）。
     * 不合法则设备轨跳过（不写入、不计数），仅 IP 轨照常计数——
     * 防键空间污染（超长串、控制字符、路径遍历字符等）。
     *
     * <p>校验逻辑委托 {@link UuidV4#isValid(String)}（UUID v4 正则唯一实现处，
     * 编码规范 §1.1）；本方法的语义来源为 KTD14，与幂等键的详设 §3.3 来源不同但格式
     * 口径一致，故共用同一正则。null / 空串 / 大写 / v1 / 无横杠均视为不合法。
     *
     * @param deviceId 设备 ID 头值
     * @return boolean；{@code true} 表示合法可入键，{@code false} 表示跳过设备轨
     */
    public static boolean isValidDeviceId(String deviceId) {
        return UuidV4.isValid(deviceId);
    }

    /**
     * 取当前自然日（Asia/Shanghai 时区，KTD6）。
     * 生产代码直接调用本方法；测试用例可直接传 {@link LocalDate} 参数绕过，
     * 便于模拟跨零点场景。
     *
     * @return {@link LocalDate} 当前日期（固定 Asia/Shanghai 时区）
     */
    public static LocalDate today() {
        return LocalDate.now(RateLimitThresholds.ZONE);
    }

    /**
     * 计算自当前时刻到次日零点（Asia/Shanghai）的剩余秒数——<b>自然日窗口「用户可见
     * 剩余秒」的唯一计算处</b>（{@code Retry-After} 真源，不含键 TTL 的 +2h 缓冲）。
     *
     * <p>[122] 的 {@link RateLimiter} 曾内置本计算（私有），[128] contact 熔断冻结标记
     * 需要同一算法（冻结键也是自然日语义、也要给出 {@code Retry-After}），
     * 第 2 处消费即按编码规范 §1.1 上浮到本类——键的过期语义与键的拼装同属「键知识」，
     * 落在本类比留在计数器里更合适。</p>
     *
     * <p>与键 TTL 的差额：键 TTL = 本值 + {@link RateLimitThresholds#NATURAL_DAY_TTL_BUFFER_SECONDS}
     * （26h 防跨日残留），而 {@code Retry-After} 必须用本值——二者混用会让用户被提示多等 2h。</p>
     *
     * @param date 当前自然日（Asia/Shanghai）
     * @return long 到次日零点的剩余秒数，恒 ≥0
     */
    public static long secondsUntilEndOfDay(LocalDate date) {
        return java.time.Duration.between(
                java.time.LocalDateTime.now(RateLimitThresholds.ZONE),
                date.plusDays(1).atStartOfDay(RateLimitThresholds.ZONE)
        ).getSeconds();
    }

    /**
     * 计算自当前时刻到下月 1 日零点（Asia/Shanghai）的剩余秒数（AI 费用月上限的
     * {@code Retry-After}）。
     *
     * <p>与 {@link #secondsUntilEndOfDay} 同属「窗口剩余秒」计算，供
     * {@code AiCostLedger} 在月累计超限时回 {@code 42901}。恒 ≥0（时钟漂移时夹到 0）。</p>
     *
     * @param month 当前自然月（Asia/Shanghai）
     * @return long 到下月零点的剩余秒数，恒 ≥0
     */
    public static long secondsUntilStartOfNextMonth(YearMonth month) {
        long seconds = java.time.Duration.between(
                java.time.LocalDateTime.now(RateLimitThresholds.ZONE),
                month.plusMonths(1).atDay(1).atStartOfDay(RateLimitThresholds.ZONE)
        ).getSeconds();
        return Math.max(0L, seconds);
    }

    /**
     * 对 Redis 键做日志脱敏——「键脱敏」的<b>唯一实现处</b>（编码规范 §1.1 第二处即上浮）。
     *
     * <p>掩码键中出现的 11 位连续数字段（手机号）中间 4 位，如
     * {@code rl:sms:phone:13800138000:1m} → {@code rl:sms:phone:138****8000:1m}，
     * 防止写失败日志把完整手机号落盘（编码规范 §4.11「日志不得出现完整手机号」）。
     * userId 通常非 11 位连续数字，不会被误掩；即便命中（极小概率）也只损失可读性，
     * 无信息泄露。</p>
     *
     * <p><b>为什么落在本类</b>：脱敏规则与「键长什么样」是同一份知识（正则命中的正是
     * 键里的手机号维度段），与本类既有的键拼装、{@link #isValidDeviceId(String)} 同类。
     * [122] 时由 {@code RateLimiter} 私有持有、[128] 又由 {@code ContactRateGuard}
     * 私有一份副本——两处逐字相同的正则，收紧脱敏规则时只改一处另一处会静默失效，
     * 而脱敏是安全红线相关逻辑（[128] 代码评审 #3）。</p>
     *
     * @param key 原始 Redis 键
     * @return {@link String} 脱敏后的键（11 位数字段中间 4 位替换为 {@code ****}）
     */
    public static String maskKey(String key) {
        return key.replaceAll("(\\d{3})\\d{4}(\\d{4})", "$1****$2");
    }
}
