package com.s2s.server.cert;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * 阿里云实人认证·信息核验的 dry-run mock 实现（[149]；DEC-30 ⑤⑩）。
 *
 * <p>职责：在真 AccessKey 联调前，用「固定测试身份白名单 + dry-run 开关」跑通
 * 实名核验全链（提交 → 核验 → 落库）。真服务联调时只需把 {@code cert.provider.dry-run}
 * 置 {@code false} 并实现真实阿里云 API 调用，业务代码（{@link CertService}）不动。</p>
 *
 * <p><b>dry-run 白名单规则</b>：身份证号末 4 位为 {@value #DRY_RUN_ID_CARD_SUFFIX}
 * 视为「核验通过」（模拟沙箱测试身份），其余视为「核验不通过」。姓名不参与判定——
 * mock 阶段无真实数据源可比对，仅以此固定规则保证测试可预测。</p>
 *
 * <p><b>安全红线</b>：本类不写任何日志（{@code realName}/{@code idCard} 为敏感明文，
 * 编码规范 §4.11 硬禁令「日志不得出现完整身份证号」）；核验失败与通过都不留痕，
 * 审计留痕由调用方（{@link CertService}）统一写 {@code audit_log}。</p>
 */
@Component
public class AliyunRealnameProvider implements RealnameProvider {

    /** dry-run 通过判定的身份证号末 4 位（模拟沙箱测试身份，[149] 编码期固定值）。 */
    private static final String DRY_RUN_ID_CARD_SUFFIX = "0000";

    /** 是否走 dry-run mock（默认 true）。真服务联调前置 false 并实现真实 API 分支。 */
    private final boolean dryRun;

    /**
     * 构造阿里云实名核验 mock 实现。
     *
     * @param dryRun 是否走 dry-run mock（配置 {@code cert.provider.dry-run}，默认 true）
     */
    public AliyunRealnameProvider(
            @Value("${cert.provider.dry-run:true}") boolean dryRun) {
        this.dryRun = dryRun;
    }

    /**
     * 二要素核验（dry-run mock）。
     *
     * <p>dry-run：身份证号末 4 位为 {@value #DRY_RUN_ID_CARD_SUFFIX} 即通过，否则不通过。
     * 非 dry-run：真阿里云 API 尚未接入，抛出 {@link IllegalStateException}（联调前不可用，
     * 由调用方映射 {@code 50302}）。</p>
     *
     * @param realName 姓名明文（mock 阶段不参与判定）
     * @param idCard   身份证号明文
     * @return {@code true} 核验通过；{@code false} 核验不通过
     * @throws IllegalStateException 非 dry-run 且真 API 未接入时抛出（认证服务不可用）
     */
    @Override
    public boolean verify(String realName, String idCard) {
        if (!dryRun) {
            throw new IllegalStateException("cert.provider.dry-run=false，但真实阿里云 API 尚未接入"
                    + "（[149] dry-run mock 阶段）");
        }
        return idCard.endsWith(DRY_RUN_ID_CARD_SUFFIX);
    }
}
