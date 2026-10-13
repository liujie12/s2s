package com.s2s.server.ops.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 临时类目 72h 判定快照实体（映射表 {@code temp_category_stat}；[153] B2-5 §9.10.2、V12）。
 *
 * <p>为什么是**快照**而非实时计数器：发布/联系属 Batch1 已验收的热路径，为后台功能在
 * 热路径上加写会引入耦合与失败面；改由到期结算任务一次性算出并存档（见 DDL 注释）。</p>
 */
@TableName("temp_category_stat")
public class TempCategoryStatEntity {

    /** 临时类目 ID（主键，与 {@code temp_category.id} 同值）。 */
    @TableId(value = "temp_category_id", type = IdType.INPUT)
    private Integer tempCategoryId;

    /** 72h 窗口内发布数。 */
    private Integer publishCount;

    /** 72h 窗口内被联系数。 */
    private Integer contactCount;

    /** 是否达标进转正候选池（1=是）。 */
    private Integer promoted;

    /** 判定时刻。 */
    private LocalDateTime evaluatedAt;

    public Integer getTempCategoryId() {
        return tempCategoryId;
    }

    public void setTempCategoryId(Integer tempCategoryId) {
        this.tempCategoryId = tempCategoryId;
    }

    public Integer getPublishCount() {
        return publishCount;
    }

    public void setPublishCount(Integer publishCount) {
        this.publishCount = publishCount;
    }

    public Integer getContactCount() {
        return contactCount;
    }

    public void setContactCount(Integer contactCount) {
        this.contactCount = contactCount;
    }

    public Integer getPromoted() {
        return promoted;
    }

    public void setPromoted(Integer promoted) {
        this.promoted = promoted;
    }

    public LocalDateTime getEvaluatedAt() {
        return evaluatedAt;
    }

    public void setEvaluatedAt(LocalDateTime evaluatedAt) {
        this.evaluatedAt = evaluatedAt;
    }
}
