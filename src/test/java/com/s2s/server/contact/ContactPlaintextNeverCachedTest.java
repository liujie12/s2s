package com.s2s.server.contact;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.auth.AuthInterceptor;
import com.s2s.server.auth.JwtVerifier;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.crypto.CryptoFacade;
import com.s2s.server.common.crypto.MasterKey;
import com.s2s.server.common.idempotency.Idempotent;
import com.s2s.server.common.idempotency.IdempotencyCaptureFilter;
import com.s2s.server.common.idempotency.IdempotencyInterceptor;
import com.s2s.server.common.web.GlobalExceptionHandler;
import com.s2s.server.common.web.RequestIdFilter;
import com.s2s.server.common.web.ResponseBodyWrapper;
import com.s2s.server.contact.dto.ContactInfo;
import com.s2s.server.contact.mapper.ContactEventMapper;
import com.s2s.server.contact.mapper.ContactPostMapper;
import com.s2s.server.contact.mapper.ReportMapper;
import jakarta.servlet.http.HttpServletRequest;
import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 「完整联系方式明文不得落 Redis 幂等缓存」守门测试（[128] 代码评审 Residual Risks 第 1 条，2026-09-28 实测）。
 *
 * <p><b>被验证的疑虑</b>（评审原文）：{@code IdempotencyCaptureFilter} 会把响应体读成字符串后送缓存，
 * 而 {@code IdempotencyInterceptor} 未按 HTTP 方法过滤、注册也未限定路径——若
 * {@code GET /posts/{id}/contact} 的请求未被 no-op，**明文联系方式就会写进 Redis**，
 * 直接违反 §9.6 数据最小化与「明文不缓存」红线。该条此前只有静态推理，无实测证据。</p>
 *
 * <p><b>三腿证据（互不依赖，任一被破坏即报红）</b>：</p>
 * <ol>
 *   <li>{@link #contactEndpointCarriesNoIdempotentAnnotation()} —— 结构守门：唯一联系方式出口
 *       的方法与类均不得携带 {@code @Idempotent}（它是「响应体进缓存」的唯一闸门）；</li>
 *   <li>{@link #contactEndpointReturnsPlaintextWithoutTouchingRedis()} —— 行为实测：以<b>真实</b>
 *       {@code IdempotencyCaptureFilter} + {@code IdempotencyInterceptor} + {@link ContactController}
 *       + {@link ContactService}（真实 {@link CryptoFacade} 解密）组装 standalone 链路，打
 *       {@code GET /posts/{id}/contact}（不带 Idempotency-Key），断言「响应体含明文」（证明明文确实
 *       流经整条链）**且该请求对 Redis 零交互**（连读都没有，写更无从发生）；</li>
 *   <li>{@link #idempotencyManagedEndpointWouldCacheThePlaintext()} —— <b>变异自检</b>：同一套装配下
 *       把同一份明文负载挂到带 {@code @Idempotent} 的 GET 上，断言明文**确实被 SET 进 Redis**。
 *       它同时证明两件事：第 2 条的绿不是「假 Redis 根本没记录」的假绿；第 1 条的结构守门为何必要。</li>
 * </ol>
 *
 * <p><b>为什么假 Redis 也算实测</b>：本测试断言的对象是「链上有没有对 Redis 发起写」，而不是
 * Redis 自身的存储行为；假 Redis 由 Mockito 记录全部交互，对「有没有写」比真 Redis 更可判
 * （真 Redis 还需要扫键反推）。真实被测件（Filter / 拦截器 / controller / service / 加解密）
 * 一律不 mock，只有外部依赖（Redis、三个 Mapper、限频守卫、审计写入）是假的。</p>
 *
 * <p><b>刻意不组装 {@code RateLimitInterceptor}</b>：它经 Lua 脚本必然访问 Redis，会把
 * 「零交互」断言变成噪声。它是计数器、不是响应体缓存写入方，与本条疑虑无关
 * （其自身行为由 {@code RateLimitInterceptorTest} 覆盖）。</p>
 *
 * <p><b>变异自检已完成（2026-09-28，实测）</b>：给真端点临时挂上 {@code @Idempotent} 后重跑，
 * ① {@code contactEndpointCarriesNoIdempotentAnnotation} 当场报红并点名注解
 * （{@code expected: null but was: @Idempotent(anonymous=false)}）；② 行为用例转为
 * 「无幂等键 → 400（40001）」；③ 再补上幂等键后转为 500 —— 500 来自未打桩的假 Redis 在
 * SETNX 处返回 null，即**真端点确实走进了幂等 Redis 路径**（而该路径成功时会把含明文的
 * 响应体 SET 进缓存，见第 3 条用例的捕获）。三处变异均已回退，现为绿。</p>
 */
class ContactPlaintextNeverCachedTest {

    /** 主密钥（version=1，32 字节 hex；与 {@code ContactServiceTest} 同源口径）。 */
    private static final MasterKey KEY_V1 =
            MasterKey.of(1, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");

    /** 发起联系者（登录态）ID：AuthInterceptor 由 mock JwtVerifier 放行后写入。 */
    private static final Long VIEWER_ID = 42L;

    /** 被联系者 ID。 */
    private static final Long OWNER_ID = 7L;

    /** 被测帖子 ID（同时作密文 AAD）。 */
    private static final Long POST_ID = 1001L;

    /** 联系方式明文（测试夹具；断言「它不得出现在任何 Redis 写入值里」）。 */
    private static final String CONTACT_VALUE = "13800138000";

    /** 合法 UUID v4 幂等键（变异自检用）。 */
    private static final String VALID_IDEM_KEY = "550e8400-e29b-41d4-a716-446655440000";

    /** 假 Redis（Mockito 记录全部交互）：负向用 {@code verifyNoInteractions}，变异用 ArgumentCaptor 捕获写入值。 */
    private StringRedisTemplate redis;

    /** 假 Redis 的值操作面（变异自检需要捕获 SET 的键值）。 */
    private ValueOperations<String, String> valueOps;

    /** 被测服务：真实加解密 + 真实编排，仅外部依赖为 mock。 */
    private ContactService service;

    /**
     * 每测前置：组装真服务与假 Redis。
     *
     * <p><b>此处不 stub {@code redis.opsForValue()}</b>：负向用例要断言「零交互」，
     * 任何前置 stub 都可能在 Mockito 的交互记录里留下噪声。</p>
     *
     * @return void
     */
    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        redis = mock(StringRedisTemplate.class);
        valueOps = mock(ValueOperations.class);

        ContactRateGuard rateGuard = mock(ContactRateGuard.class);
        when(rateGuard.remainingToday(anyLong(), any())).thenReturn(27);

        ContactPostMapper postMapper = mock(ContactPostMapper.class);
        CryptoFacade cryptoFacade = new CryptoFacade(List.of(KEY_V1));
        when(postMapper.selectContactRow(POST_ID))
                .thenReturn(row(POST_ID, ciphertext(POST_ID)));

        service = new ContactService(rateGuard, postMapper,
                mock(ContactEventMapper.class), mock(ReportMapper.class),
                cryptoFacade, mock(AuditLogWriter.class), new ObjectMapper());
    }

    /**
     * 结构守门：唯一联系方式出口不得挂 {@code @Idempotent}。
     *
     * <p>{@code @Idempotent} 是全库唯一「响应体进 Redis」的闸门（见
     * {@link IdempotencyCaptureFilter}）：一旦挂上，该接口的完整信封 JSON
     * （含 {@code contact_value} 明文）就会被缓存 {@code NfrApi.IDEMPOTENCY_WINDOW_HOURS} 小时。</p>
     *
     * @return void；断言失败即明文缓存红线被打开
     * @throws NoSuchMethodException 端点签名变更时抛出（签名本应稳定，变更须显式同步本守门）
     */
    @Test
    void contactEndpointCarriesNoIdempotentAnnotation() throws NoSuchMethodException {
        Method endpoint = ContactController.class.getMethod(
                "getPostContact", Long.class, HttpServletRequest.class);

        assertThat(endpoint.getAnnotation(Idempotent.class))
                .as("getPostContact 不得挂 @Idempotent —— 它会把含明文联系方式的响应体写进 Redis 幂等缓存")
                .isNull();
        assertThat(ContactController.class.getAnnotation(Idempotent.class))
                .as("类级 @Idempotent 同样会波及本端点，不得存在")
                .isNull();
    }

    /**
     * 行为实测：真实链路打 {@code GET /posts/{id}/contact}，明文出得去、Redis 一次没碰。
     *
     * @return void；断言失败即明文已进入幂等缓存链路（§9.6 红线）
     * @throws Exception MockMvc 执行异常（测试固有问题）
     */
    @Test
    void contactEndpointReturnsPlaintextWithoutTouchingRedis() throws Exception {
        MockMvc mvc = buildMockMvc(new ContactController(service));

        String body = mvc.perform(get("/posts/" + POST_ID + "/contact")
                        .header("Authorization", "Bearer test-token"))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString();

        // 前提证据：明文真的被解密并写出了（否则「没写 Redis」只是链路没跑通的假绿）
        assertThat(body).contains(CONTACT_VALUE);
        // 主判据：整条链对该 Redis 零交互 —— 读都没有，写更不可能
        verifyNoInteractions(redis);
    }

    /**
     * 变异自检：把同一份明文负载挂到带 {@code @Idempotent} 的 GET 上，明文**会**被缓存。
     *
     * <p>本条若变绿（不再捕获到写入），说明假 Redis 的记录能力失灵 —— 上一条的绿也就不足采信。</p>
     *
     * @return void；断言失败即变异未生效（守门失去反证能力）
     * @throws Exception MockMvc 执行异常（测试固有问题）
     */
    @Test
    void idempotencyManagedEndpointWouldCacheThePlaintext() throws Exception {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.setIfAbsent(anyString(), anyString(), anyLong(), eq(TimeUnit.SECONDS)))
                .thenReturn(true);

        MockMvc mvc = buildMockMvc(new IdempotentPlaintextStub());
        mvc.perform(get("/stub/contact-idempotent")
                        .header("Authorization", "Bearer test-token")
                        .header("Idempotency-Key", VALID_IDEM_KEY))
                .andExpect(status().isOk());

        ArgumentCaptor<String> cachedBody = ArgumentCaptor.forClass(String.class);
        verify(valueOps).set(anyString(), cachedBody.capture(), anyLong(), eq(TimeUnit.SECONDS));

        assertThat(cachedBody.getValue())
                .as("注解在 → 响应体（含明文）确实被 SET 进 Redis，故结构守门不可省")
                .contains(CONTACT_VALUE);
    }

    /**
     * 组装 standalone MockMvc：真实幂等链 + 真实鉴权拦截器 + 真 controller，
     * 链序与 {@code WebCrosscutConfig} 一致（{@code RequestIdFilter → AuthInterceptor →
     * IdempotencyInterceptor}；{@code IdempotencyCaptureFilter} 在 Filter 层）。
     *
     * @param controllers 参与映射的 controller（真 {@link ContactController} 或变异 stub）
     * @return {@link MockMvc} 已组装链路
     */
    private MockMvc buildMockMvc(Object... controllers) {
        JwtVerifier jwtVerifier = mock(JwtVerifier.class);
        when(jwtVerifier.verifyAndGetUserId(anyString())).thenReturn(VIEWER_ID);

        return MockMvcBuilders.standaloneSetup(controllers)
                .addFilters(new RequestIdFilter(), new IdempotencyCaptureFilter(redis))
                .addInterceptors(new AuthInterceptor(jwtVerifier), new IdempotencyInterceptor(redis))
                .setControllerAdvice(new GlobalExceptionHandler(),
                        new ResponseBodyWrapper(new ObjectMapper()))
                .build();
    }

    /**
     * 构造帖子行夹具（列名与 {@code ContactPostMapper.xml} 的 SELECT 列集合一致）。
     *
     * @param postId     帖子 ID
     * @param ciphertext 联系方式密文
     * @return {@link Map} 六列行
     */
    private static Map<String, Object> row(Long postId, byte[] ciphertext) {
        Map<String, Object> row = new HashMap<>();
        row.put("id", postId);
        row.put("user_id", OWNER_ID);
        row.put("contact_channel", "phone");
        row.put("contact_value_enc", ciphertext);
        row.put("key_version", 1);
        row.put("status", "active");
        return row;
    }

    /**
     * 用指定帖子 ID 作 AAD 加密明文（模拟 [125] 发布链的写入结果）。
     *
     * @param postId AAD（帖子 ID）
     * @return {@code byte[]} 密文
     */
    private static byte[] ciphertext(Long postId) {
        return new CryptoFacade(List.of(KEY_V1))
                .encrypt(CONTACT_VALUE, String.valueOf(postId)).ciphertext();
    }

    /**
     * 变异用 stub：把同一份明文负载挂在带 {@code @Idempotent} 的 GET 上。
     *
     * <p>只存在于测试内，不污染主源码；它回答的是「若这个注解挂上去会怎样」。</p>
     */
    @RestController
    static class IdempotentPlaintextStub {

        /**
         * 幂等标注的联系方式出口（变异场景）。
         *
         * @return {@link ContactInfo} 与真实端点同形的明文负载
         */
        @Idempotent
        @GetMapping("/stub/contact-idempotent")
        public ContactInfo contact() {
            return new ContactInfo("phone", CONTACT_VALUE, 27);
        }
    }
}
