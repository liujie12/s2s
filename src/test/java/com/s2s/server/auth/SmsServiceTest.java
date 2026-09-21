package com.s2s.server.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.auth.dto.SendCodeRequest;
import com.s2s.server.auth.dto.SendCodeResult;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimiter;
import java.time.Duration;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

/**
 * {@link SmsService} 发码测试（[123] U4；详设 §5.1；plan U4 验收三条）。
 *
 * <p>覆盖场景：
 * <ol>
 *   <li>发送成功 → 返回 {@code expire_in=300}，Redis 写 {@code sms:{phone}} 键；</li>
 *   <li>限频四轨拼装 → 手机号 1m/1h/1d + IP 1h 共 4 条 entry；</li>
 *   <li>限频超限 → 传播 {@code BizException}(42905 + Retry-After)。</li>
 * </ol>
 *
 * <p>测试策略：Redis 与限频计数器用 Mockito mock（计数/存储逻辑在各自单测覆盖），
 * 本测试聚焦 {@code sendCode} 的编排——限频直调、键拼装、存储键、返回 TTL；
 * ObjectMapper 用真实实例（{@code findAndRegisterModules} 注册 JavaTimeModule 序列化 Instant）。</p>
 */
class SmsServiceTest {

    /** mock 的 Redis 模板。 */
    private StringRedisTemplate redisTemplate;

    /** mock 的字符串 value 操作（验证码存储）。 */
    @SuppressWarnings("unchecked")
    private ValueOperations<String, String> valueOps;

    /** mock 的限频计数器。 */
    private RateLimiter rateLimiter;

    /** 被测短信验证码服务。 */
    private SmsService smsService;

    /**
     * 每测前置：构造 mock Redis/限频与真实 ObjectMapper，装配被测服务。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        redisTemplate = mock(StringRedisTemplate.class);
        valueOps = mock(ValueOperations.class);
        when(redisTemplate.opsForValue()).thenReturn(valueOps);
        rateLimiter = mock(RateLimiter.class);
        ObjectMapper objectMapper = new ObjectMapper().findAndRegisterModules();
        smsService = new SmsService(redisTemplate, rateLimiter, objectMapper);
    }

    /**
     * 场景一：发送成功 → 返回 expire_in=300，Redis 写 sms:{phone} 键。
     *
     * @return void；断言失败即返回 TTL 错误或存储键拼错
     */
    @Test
    void sendCodeReturnsTtlAndStoresCode() {
        SendCodeRequest request = new SendCodeRequest("13800138000", "login");

        SendCodeResult result = smsService.sendCode(request, "127.0.0.1");

        assertThat(result.expireIn()).isEqualTo(300);
        verify(rateLimiter).incrementAndCheck(anyList());
        ArgumentCaptor<String> keyCaptor = ArgumentCaptor.forClass(String.class);
        verify(valueOps).set(keyCaptor.capture(), anyString(), any(Duration.class));
        assertThat(keyCaptor.getValue()).isEqualTo("sms:13800138000");
    }

    /**
     * 场景二：限频四轨拼装 → 手机号 1m/1h/1d + IP 1h 共 4 条 entry，键形正确。
     *
     * @return void；断言失败即限频键拼装或轨数错误
     */
    @Test
    void sendCodeBuildsFourRateLimitEntries() {
        SendCodeRequest request = new SendCodeRequest("13800138000", "login");

        smsService.sendCode(request, "127.0.0.1");

        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<RateLimiter.RateLimitEntry>> captor = ArgumentCaptor.forClass(List.class);
        verify(rateLimiter).incrementAndCheck(captor.capture());
        List<RateLimiter.RateLimitEntry> entries = captor.getValue();
        assertThat(entries).hasSize(4);
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .anyMatch(k -> k.startsWith("rl:sms:phone:13800138000:1m"));
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .anyMatch(k -> k.startsWith("rl:sms:phone:13800138000:1h"));
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .anyMatch(k -> k.startsWith("rl:sms:phone:13800138000:1d:"));
        assertThat(entries).extracting(RateLimiter.RateLimitEntry::key)
                .anyMatch(k -> k.startsWith("rl:sms:ip:127.0.0.1:1h"));
    }

    /**
     * 场景三：限频超限 → 传播 BizException（42905 + Retry-After）。
     *
     * @return void；断言失败即超限异常被吞掉或码/秒数错误
     */
    @Test
    void sendCodeOverLimitPropagates() {
        SendCodeRequest request = new SendCodeRequest("13800138000", "login");
        doThrow(BizException.ofRetryAfter(ErrorCode.SMS_LIMIT, 60))
                .when(rateLimiter).incrementAndCheck(anyList());

        assertThatThrownBy(() -> smsService.sendCode(request, "127.0.0.1"))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> {
                    BizException biz = (BizException) ex;
                    assertThat(biz.getErrorCode()).isEqualTo(ErrorCode.SMS_LIMIT);
                    assertThat(biz.getRetryAfterSeconds()).isEqualTo(60L);
                });
    }
}
