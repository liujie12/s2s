package com.s2s.server.cert;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * 阿里云实人认证·信息核验（身份二要素 {@code Id2MetaVerify}）实现。
 *
 * <p>两种运行形态：</p>
 * <ul>
 *   <li><b>dry-run</b>（{@code cert.provider.dry-run=true}，当前生产默认）：不调外部，
 *       只按「身份证末 4 位是否 {@value #DRY_RUN_ID_CARD_SUFFIX}」判定，用于无 AK 阶段跑通全链；</li>
 *   <li><b>真实核验</b>（{@code false}）：经 {@link CloudAuthId2MetaClient} 调用阿里云，
 *       密钥缺失时<b>启动即失败</b>——宁可发版失败，也不让线上怀着空配置跑。</li>
 * </ul>
 *
 * <p><b>安全红线</b>：本类不写任何日志（{@code realName}/{@code idCard} 为敏感明文，
 * 编码规范 §4.11 硬禁令「日志不得出现完整身份证号」）。审计留痕由调用方
 * （{@link CertService}）统一写 {@code audit_log}。</p>
 */
@Component
public class AliyunRealnameProvider implements RealnameProvider {

    /** dry-run 通过判定的身份证号末 4 位（模拟沙箱测试身份）。 */
    private static final String DRY_RUN_ID_CARD_SUFFIX = "0000";

    /** 是否走 dry-run mock。 */
    private final boolean dryRun;

    /** 真实核验客户端；dry-run 时为 null（不构造、不持有任何密钥）。 */
    private final CloudAuthId2MetaClient client;

    /**
     * 构造实名核验实现。
     *
     * @param dryRun          是否走 dry-run mock（{@code cert.provider.dry-run}，默认 true）
     * @param endpoint        信息核验服务地址（{@code cert.provider.endpoint}）
     * @param accessKeyId     RAM 用户 AccessKeyId（{@code cert.provider.access-key-id}）
     * @param accessKeySecret RAM 用户 AccessKeySecret（{@code cert.provider.access-key-secret}）
     * @throws IllegalStateException 非 dry-run 且 AK 未配置（启动期快速失败）
     */
    public AliyunRealnameProvider(
            @Value("${cert.provider.dry-run:true}") boolean dryRun,
            @Value("${cert.provider.endpoint:https://cloudauth.cn-beijing.aliyuncs.com}")
            String endpoint,
            @Value("${cert.provider.access-key-id:}") String accessKeyId,
            @Value("${cert.provider.access-key-secret:}") String accessKeySecret) {
        this.dryRun = dryRun;
        if (dryRun) {
            this.client = null;
            return;
        }
        if (accessKeyId == null || accessKeyId.isBlank()
                || accessKeySecret == null || accessKeySecret.isBlank()) {
            throw new IllegalStateException(
                    "cert.provider.dry-run=false 但未配置 CLOUDAUTH_ACCESS_KEY_ID / "
                            + "CLOUDAUTH_ACCESS_KEY_SECRET：拒绝以空凭据启动");
        }
        this.client = new CloudAuthId2MetaClient(endpoint, accessKeyId, accessKeySecret);
    }

    /**
     * 二要素核验。
     *
     * <p>dry-run：身份证号末 4 位为 {@value #DRY_RUN_ID_CARD_SUFFIX} 即通过，否则不通过；
     * 真实模式：转发阿里云 {@code Id2MetaVerify}，{@code BizCode=1} 通过、{@code 2} 不通过。</p>
     *
     * @param realName 姓名明文
     * @param idCard   身份证号明文
     * @return {@code true} 核验通过；{@code false} 核验不通过
     * @throws IllegalStateException 上游不可用（调用方映射 {@code 50302}）
     */
    @Override
    public boolean verify(String realName, String idCard) {
        if (dryRun) {
            return idCard.endsWith(DRY_RUN_ID_CARD_SUFFIX);
        }
        return client.verify(realName, idCard);
    }
}
