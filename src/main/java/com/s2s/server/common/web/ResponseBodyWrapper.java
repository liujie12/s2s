package com.s2s.server.common.web;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.error.ErrorCode;
import java.util.UUID;
import org.springframework.core.MethodParameter;
import org.springframework.http.MediaType;
import org.springframework.http.converter.HttpMessageConverter;
import org.springframework.http.server.ServerHttpRequest;
import org.springframework.http.server.ServerHttpResponse;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.context.request.RequestAttributes;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.servlet.mvc.method.annotation.ResponseBodyAdvice;

/**
 * 全系统<b>唯一响应套壳与 {@code request_id} 注入处</b>（详设 §2.1；编码规范 §1.2 唯一实现处清单）。
 *
 * <p>职责（详设 §2.1 包装器职责）：
 * <ol>
 *   <li>controller 直接返回业务 DTO——本类不提供 {@code ok(...)} 静态工厂，
 *       业务代码手写 {@code ApiResponse} 包装即缺陷（静态扫描 {@code ApiResponse.ok} 零命中守门）；</li>
 *   <li>对 controller 返回值统一套壳 {@link ApiResponse} 并注入当前请求的 {@code request_id}；</li>
 *   <li>{@code /track/events} 也走统一包装，无例外；{@code /actuator/**} 运维端点不套壳
 *       （compose healthcheck 依赖原生格式，部署架构设计文档）。</li>
 * </ol>
 *
 * <p>{@code request_id} 实现：从请求属性 {@link #REQUEST_ID_ATTRIBUTE} 读取，
 * 取不到则生成 UUID 放入；[122] {@code RequestIdFilter} 已在链首
 * 生成并写入同一属性，本方法与 {@code GlobalExceptionHandler} 仅读取，生成逻辑为防御性兜底。
 */
@RestControllerAdvice
public class ResponseBodyWrapper implements ResponseBodyAdvice<Object> {

    /**
     * {@code request_id} 的请求属性键。[122] {@code RequestIdFilter} 在链首写入本键；
     * {@code GlobalExceptionHandler} 与本类经 {@link #resolveOrCreateRequestId()} 共享读取。
     */
    public static final String REQUEST_ID_ATTRIBUTE = "X_REQUEST_ID";

    /** actuator 运维端点路径前缀：命中即原样放行不套壳（U-3 任务书明列排除路径）。 */
    private static final String ACTUATOR_PATH_PREFIX = "/actuator";

    private final ObjectMapper objectMapper;

    /**
     * 构造包装器，注入 Spring 托管的 {@link ObjectMapper}（与全局序列化配置一致，
     * 仅用于 String 返回值分支的手动序列化）。
     *
     * @param objectMapper Spring 容器中的 Jackson 序列化器
     */
    public ResponseBodyWrapper(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    /**
     * 判定是否对当前返回值执行套壳：声明返回类型已是 {@link ApiResponse} 的端点不二次套壳
     * （如 {@code GlobalExceptionHandler} 的返回值），其余一律套壳。
     *
     * @param returnType    controller 方法返回类型描述
     * @param converterType Spring 选中的消息转换器类型
     * @return boolean；{@code false} 表示放行不套壳
     */
    @Override
    public boolean supports(MethodParameter returnType,
            Class<? extends HttpMessageConverter<?>> converterType) {
        return !ApiResponse.class.isAssignableFrom(returnType.getParameterType());
    }

    /**
     * 写出前统一套壳：已套壳值与 {@code /actuator/**} 原样放行；其余包装为
     * {@code ApiResponse(code=0, message=OK.message, data=body, request_id=当前请求)}。
     * String 返回值走 {@code StringHttpMessageConverter}，必须手动序列化为 JSON 字符串
     * 并把 Content-Type 纠正为 {@code application/json}，否则转换器无法处理 record 对象。
     *
     * @param body                  controller 实际返回值
     * @param returnType            controller 方法返回类型描述
     * @param selectedContentType   协商出的响应 Content-Type
     * @param selectedConverterType Spring 选中的消息转换器类型
     * @param request               当前请求（actuator 路径判定依据）
     * @param response              当前响应（String 分支纠正 Content-Type）
     * @return 套壳后的 {@link ApiResponse}；String 分支为其 JSON 字符串；放行场景为原 {@code body}
     */
    @Override
    public Object beforeBodyWrite(Object body, MethodParameter returnType, MediaType selectedContentType,
            Class<? extends HttpMessageConverter<?>> selectedConverterType,
            ServerHttpRequest request, ServerHttpResponse response) {
        // 防线一：body 已是 ApiResponse（声明类型防线之外的运行时兜底）——不二次套壳
        if (body instanceof ApiResponse<?>) {
            return body;
        }
        // 防线二：/actuator/** 运维端点原样放行（healthcheck 依赖原生格式）
        if (request.getURI().getPath().startsWith(ACTUATOR_PATH_PREFIX)) {
            return body;
        }
        ApiResponse<Object> wrapped = new ApiResponse<>(
                ErrorCode.OK.getCode(), ErrorCode.OK.getMessage(), body, resolveOrCreateRequestId());
        if (body instanceof String) {
            response.getHeaders().setContentType(MediaType.APPLICATION_JSON);
            return serializeToJson(wrapped);
        }
        return wrapped;
    }

    /**
     * 解析当前请求的 {@code request_id}（从 {@link RequestContextHolder} 线程本地取当前请求）：
     * 优先读请求属性 {@link #REQUEST_ID_ATTRIBUTE}
     * （[122] {@code RequestIdFilter} 链首生成的正式写入点）；Filter 链首生成，此处仅防御性兜底——
     * 属性缺失时生成 UUID 并回写，保证同一请求内 wrapper 与 handler 取到同一值；非请求线程兜底直接生成。
     * 本方法是该逻辑的<b>唯一实现处</b>（编码规范 §1.1 反冗余），{@code GlobalExceptionHandler} 复用。
     *
     * @return {@link String} 当前请求的 {@code request_id}，非空
     */
    public static String resolveOrCreateRequestId() {
        RequestAttributes attributes = RequestContextHolder.getRequestAttributes();
        if (attributes == null) {
            // 非请求线程（理论不可达：advice/handler 均在请求线程执行）——防御性兜底
            return UUID.randomUUID().toString();
        }
        Object existing = attributes.getAttribute(REQUEST_ID_ATTRIBUTE, RequestAttributes.SCOPE_REQUEST);
        if (existing instanceof String requestId && !requestId.isBlank()) {
            return requestId;
        }
        String generated = UUID.randomUUID().toString();
        attributes.setAttribute(REQUEST_ID_ATTRIBUTE, generated, RequestAttributes.SCOPE_REQUEST);
        return generated;
    }

    /**
     * 将套壳结果序列化为 JSON 字符串（仅供 String 返回值分支使用）。
     * 序列化失败属服务端缺陷，抛出后由 {@code GlobalExceptionHandler} 兜底映射 50001。
     *
     * @param response 已套壳的 {@link ApiResponse}
     * @return {@link String} JSON 文本（snake_case，含 {@code request_id}）
     */
    private String serializeToJson(ApiResponse<?> response) {
        try {
            return objectMapper.writeValueAsString(response);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("ApiResponse 序列化失败，无法写出响应", exception);
        }
    }
}
