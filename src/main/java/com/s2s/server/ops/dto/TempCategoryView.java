package com.s2s.server.ops.dto;

import com.s2s.server.ops.entity.TempCategoryEntity;
import com.s2s.server.ops.entity.TempCategoryStatEntity;
import java.time.LocalDateTime;

/**
 * 临时类目视图（[153] B2-5 §9.10.2；ops 域内部出参）。
 *
 * <p>为什么把「生命周期元数据」与「72h 判定快照」合成一个视图：后台一屏里既要看
 * 「这条临时类目什么状态」，也要看「它 72h 内的发布/联系数与是否达标」——两表 1:1，
 * 合成一个视图避免调用方自行 join 与判空。快照在结算前<b>不存在</b>，故
 * {@code publishCount}/{@code contactCount}/{@code promoted} 可为 {@code null}。</p>
 *
 * @param id           临时叶子类目 ID（= category.id）
 * @param l2ParentId   挂载的「临时」二级类目 ID
 * @param name         临时类目名
 * @param status       生命周期：{@code active}/{@code expired}/{@code promoted}
 * @param createdBy    创建人（后台 admin_user.id）
 * @param createdAt    创建时间
 * @param expireAt     自动下线时刻（created_at + 72h）
 * @param closedAt     结算时刻（未结算为 null）
 * @param publishCount 72h 窗口内发布数（未结算为 null）
 * @param contactCount 72h 窗口内被联系数（未结算为 null）
 * @param promoted     是否达标进转正候选池（未结算为 null；1=是 / 0=否）
 */
public record TempCategoryView(
        Integer id,
        Integer l2ParentId,
        String name,
        String status,
        Long createdBy,
        LocalDateTime createdAt,
        LocalDateTime expireAt,
        LocalDateTime closedAt,
        Integer publishCount,
        Integer contactCount,
        Integer promoted) {

    /**
     * 由「生命周期实体 +（可空的）判定快照」组装视图。
     *
     * @param entity 临时类目实体
     * @param stat   判定快照；未结算时为 {@code null}
     * @return {@link TempCategoryView} 视图
     */
    public static TempCategoryView of(TempCategoryEntity entity, TempCategoryStatEntity stat) {
        return new TempCategoryView(
                entity.getId(),
                entity.getL2ParentId(),
                entity.getName(),
                entity.getStatus(),
                entity.getCreatedBy(),
                entity.getCreatedAt(),
                entity.getExpireAt(),
                entity.getClosedAt(),
                stat == null ? null : stat.getPublishCount(),
                stat == null ? null : stat.getContactCount(),
                stat == null ? null : stat.getPromoted());
    }
}
