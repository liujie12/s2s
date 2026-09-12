package com.s2s.server.common.web;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 统一响应包。所有接口无论成功失败均返回该结构（详设 §2.1 逐字落地；
 * 含 {@code POST /track/events}，无例外）。对外 JSON 一律 {@code snake_case}
 * 与 OpenAPI 逐字一致（编码规范 §2.1），故类级声明 Jackson 命名策略，
 * 序列化出 {@code request_id}。
 *
 * @param code      业务码，0 成功；非 0 见 {@code ErrorCode}，前 3 位与 HTTP 状态码对齐
 * @param message   中文文案，非 0 时可直接呈现给用户
 * @param data      业务负载，失败时恒为 null
 * @param requestId 服务端生成，UI 报错唯一回显值（缓存命中时可不存在，预期行为）
 * @param <T>       业务负载类型
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ApiResponse<T>(
        int code,
        String message,
        T data,
        String requestId
) {
}
