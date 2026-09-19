package com.s2s.server.common.web;

import java.util.regex.Pattern;

/**
 * UUID v4 格式校验<b>唯一实现处</b>（[122] U5；编码规范 §1.1「正则出现第 2 次前必须提取」）。
 *
 * <p>提取依据：请求头 {@code X-Device-Id}（KTD14）与 {@code Idempotency-Key}
 * （详设 §3.3）两处都要求 UUID v4 格式（小写、含横杠、版本位 4、变体位 8/9/a/b），
 * 正则字面量完全相同。若两处各自私有正则，任一处口径漂移即产生「同构异值」隐患，
 * 故收敛为本类唯一正则，两消费方只引用不重写（跨调用点镜像不算冗余，
 * 但「同端正则两处私有」属于禁止的复制）。
 *
 * <p><b>格式口径</b>：小写十六进制 8-4-4-4-12，第三组首位为 4（版本），
 * 第四组首位为 [89ab]（RFC 4122 变体）。大写 / v1（版本位 1）/ 无横杠 /
 * 空 / 非十六进制字符均判非法。两消费点的语义来源不同但格式口径一致：
 * <ul>
 *   <li>{@code X-Device-Id}：前端首次启动自生成 UUID（KTD14，不合规则跳过设备轨）；</li>
 *   <li>{@code Idempotency-Key}：契约要求客户端生成 UUID v4（详设 §3.3，
 *       不合法返 40001 不放行）。</li>
 * </ul>
 *
 * <p>本类纯静态、无状态、纯函数式。
 */
public final class UuidV4 {

    /** UUID v4 标准格式正则。RFC 4122：版本位 4、变体位 [89ab]、小写十六进制、含横杠。 */
    private static final Pattern PATTERN = Pattern.compile(
            "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$");

    /**
     * 工具类：禁止实例化。
     */
    private UuidV4() {
        throw new AssertionError("UuidV4 是工具类，不可实例化");
    }

    /**
     * 校验字符串是否为合法 UUID v4 格式。
     *
     * @param value 待校验字符串，可为 {@code null}
     * @return boolean；{@code true} 表示合法（小写、含横杠、版本 4、变体 [89ab]）；
     *         {@code null} / 空串 / 大写 / v1 / 无横杠均返回 {@code false}
     */
    public static boolean isValid(String value) {
        return value != null && PATTERN.matcher(value).matches();
    }
}