package com.s2s.server.common.ratelimit;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.web.UuidV4;
import java.time.LocalDate;
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

    /** 自然日窗口日期格式（yyyyMMdd）。 */
    private static final DateTimeFormatter DATE_FORMAT = DateTimeFormatter.ofPattern("yyyyMMdd");

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
}
