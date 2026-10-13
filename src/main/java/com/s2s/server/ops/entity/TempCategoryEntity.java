package com.s2s.server.ops.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 72h 临时类目实体（映射表 {@code temp_category}；[153] B2-5 §9.10.2、DDL {@code V12}）。
 *
 * <p>字段与 DDL 逐列对齐。{@code id} 与 {@code category.id} 同值（叶子类目 ID =
 * L2×100+序号）——本表是分类树中那条叶子行的**生命周期与运营归属**扩展元数据（1:1），
 * 不是分类树的替代品。</p>
 */
@TableName("temp_category")
public class TempCategoryEntity {

    /** 临时叶子类目 ID（主键 = category.id，非自增）。 */
    @TableId(value = "id", type = IdType.INPUT)
    private Integer id;

    /** 挂载的「临时」二级类目 ID。 */
    private Integer l2ParentId;

    /** 临时类目名。 */
    private String name;

    /** 生命周期：{@code active}/{@code expired}/{@code promoted}。 */
    private String status;

    /** 创建人（后台 admin_user.id）。 */
    private Long createdBy;

    /** 创建时间（库内默认值，服务端不写）。 */
    private LocalDateTime createdAt;

    /** 自动下线时刻（created_at + 72h）。 */
    private LocalDateTime expireAt;

    /** 结算时刻（任务写入）。 */
    private LocalDateTime closedAt;

    public Integer getId() {
        return id;
    }

    public void setId(Integer id) {
        this.id = id;
    }

    public Integer getL2ParentId() {
        return l2ParentId;
    }

    public void setL2ParentId(Integer l2ParentId) {
        this.l2ParentId = l2ParentId;
    }

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public Long getCreatedBy() {
        return createdBy;
    }

    public void setCreatedBy(Long createdBy) {
        this.createdBy = createdBy;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(LocalDateTime createdAt) {
        this.createdAt = createdAt;
    }

    public LocalDateTime getExpireAt() {
        return expireAt;
    }

    public void setExpireAt(LocalDateTime expireAt) {
        this.expireAt = expireAt;
    }

    public LocalDateTime getClosedAt() {
        return closedAt;
    }

    public void setClosedAt(LocalDateTime closedAt) {
        this.closedAt = closedAt;
    }
}
