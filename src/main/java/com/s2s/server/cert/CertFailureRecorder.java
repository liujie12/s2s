package com.s2s.server.cert;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.cert.entity.CertEntity;
import com.s2s.server.cert.mapper.CertMapper;
import com.s2s.server.common.constants.NfrCert;
import java.time.LocalDateTime;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * 实名核验失败计数与锁定记录器（[149] 评审 P0/P1 修复）。
 *
 * <p>职责：承载「二要素核验失败 → 记 {@code cert.fail_count} + 达阈值写
 * {@code cert.lock_until}」的持久化，与 {@link CertService#submitRealname} 的核验成功
 * 落库路径<b>解耦</b>——见下「为什么必须独立事务」。</p>
 *
 * <p><b>为什么 {@link #recordFailure} 必须 {@code REQUIRES_NEW} 独立事务</b>（评审 P0）：
 * {@code submitRealname} 整体标 {@code @Transactional}，核验失败分支「先记失败计数、再
 * {@code throw BizException(PARAM_INVALID)}」，而 {@code BizException} 是
 * {@code RuntimeException}，Spring 默认对其回滚——若失败计数写在同一事务，会随异常
 * 一并回滚、{@code fail_count}/{@code lock_until} 从未持久化，防刷锁定形同虚设
 * （PRD §4.8「二要素 3 次失败锁 24h」失效）。故失败留痕须在业务异常回滚<b>之前</b>
 * 于独立事务提交，与 {@code audit_log}「必须与业务同事务」恰好相反——审计要的是
 * 「操作成功才留痕」，失败计数要的是「失败也必须留痕」。</p>
 *
 * <p><b>锁过期后重新计数（评审 P1 技术部分）</b>：{@code fail_count} 在未锁定
 * （{@code lock_until}=null）或锁定期内累加，{@code lock_until} 过期后归零重计，
 * 避免「解锁后每次仅 1 次尝试即再锁」的退化。锁定的「自然过期恢复 vs 人工申诉」口径
 * 冲突已登记待裁定（见 {@link CertService} 类注释），本类不代裁定。</p>
 */
@Component
public class CertFailureRecorder {

    /** 认证 Mapper（cert 表，本域自有）。 */
    private final CertMapper certMapper;

    /**
     * 构造失败计数记录器。
     *
     * @param certMapper cert 表 Mapper
     */
    public CertFailureRecorder(CertMapper certMapper) {
        this.certMapper = certMapper;
    }

    /**
     * 判断用户是否处于实名核验锁定期（只读，无事务）。
     *
     * @param userId 用户 ID
     * @return {@code true} 表示 {@code lock_until} 未过期（锁定期内，应拒绝提交）
     */
    public boolean isLocked(Long userId) {
        CertEntity latest = latestRealnameCert(userId);
        return latest != null && latest.getLockUntil() != null
                && latest.getLockUntil().isAfter(LocalDateTime.now());
    }

    /**
     * 记录一次核验失败并在达阈值时锁定（独立事务 {@code REQUIRES_NEW}）。
     *
     * <p>锁过期后重新计数（评审 P1）：仅当最新记录仍处锁定期（{@code lock_until} 未过期）
     * 或从未锁定（{@code lock_until}=null）才保留累计；{@code lock_until} 已过期则归零重计
     * ——避免「解锁后一次失败即再锁」。</p>
     *
     * @param userId 用户 ID
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void recordFailure(Long userId) {
        CertEntity latest = latestRealnameCert(userId);
        LocalDateTime now = LocalDateTime.now();

        int failCount = 0;
        if (latest != null && latest.getFailCount() != null) {
            LocalDateTime lockUntil = latest.getLockUntil();
            // 仅当锁已过期（lockUntil 早于当前）才重新计数；未锁定（null）或仍在锁定期则保留累计
            boolean expired = lockUntil != null && lockUntil.isBefore(now);
            if (!expired) {
                failCount = latest.getFailCount();
            }
        }
        int next = failCount + 1;

        if (latest == null) {
            CertEntity entity = new CertEntity();
            entity.setUserId(userId);
            entity.setCertType(CertService.CERT_TYPE_PERSONAL_REALNAME);
            entity.setStatus(CertService.CERT_STATUS_PENDING);
            entity.setFailCount(next);
            if (next >= NfrCert.REALNAME_FAIL_LOCK_THRESHOLD) {
                entity.setLockUntil(now.plusSeconds(NfrCert.REALNAME_FAIL_LOCK_SECONDS));
            }
            certMapper.insert(entity);
        } else {
            latest.setFailCount(next);
            // 达阈值才写 lock_until；未达（含锁过期后重新计数）则清空旧 lock_until
            latest.setLockUntil(next >= NfrCert.REALNAME_FAIL_LOCK_THRESHOLD
                    ? now.plusSeconds(NfrCert.REALNAME_FAIL_LOCK_SECONDS)
                    : null);
            certMapper.updateById(latest);
        }
    }

    /**
     * 取该用户最新一条个人实名 cert 记录（用于锁定判定与失败计数，无则 null）。
     *
     * @param userId 用户 ID
     * @return {@link CertEntity} 最新实名记录；无记录返回 {@code null}
     */
    private CertEntity latestRealnameCert(Long userId) {
        return certMapper.selectOne(new QueryWrapper<CertEntity>()
                .eq("user_id", userId)
                .eq("cert_type", CertService.CERT_TYPE_PERSONAL_REALNAME)
                .orderByDesc("id")
                .last("LIMIT 1"));
    }
}
