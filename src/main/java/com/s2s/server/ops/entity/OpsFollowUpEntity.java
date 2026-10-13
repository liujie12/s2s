package com.s2s.server.ops.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 待运营跟进队列实体（映射表 {@code ops_follow_up}；[153] B2-5 ⑥、PRD §6.4.4）。
 *
 * <p>字段与 DDL {@code V11__ops_follow_up.sql} 逐列对齐。队列条目由「检索空结果」
 * 触发写入，由运营在后台处理（{@code pending → handled}）。</p>
 *
 * <p><b>隐私取舍</b>：只存粗粒度 {@code gridId}，不存精确经纬度（见 DDL 注释）。</p>
 */
@TableName("ops_follow_up")
public class OpsFollowUpEntity {

    /** 队列条目 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 触发检索的用户（游客为空）。 */
    private Long userId;

    /** 检索关键词（可空＝纯类目检索）。 */
    private String keyword;

    /** 检索的二级类目 ID（可空）。 */
    private Integer l2CategoryId;

    /** 坐标网格（约 500m，粗粒度）。 */
    private String gridId;

    /** 处理状态：{@code pending}/{@code handled}。 */
    private String status;

    /** 处理人（后台 admin_user.id）。 */
    private Long handlerId;

    /** 处理时间。 */
    private LocalDateTime handledAt;

    /** 处理备注。 */
    private String remark;

    /** 入队时间（库内 DEFAULT CURRENT_TIMESTAMP，服务端不写）。 */
    private LocalDateTime triggeredAt;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public Long getUserId() {
        return userId;
    }

    public void setUserId(Long userId) {
        this.userId = userId;
    }

    public String getKeyword() {
        return keyword;
    }

    public void setKeyword(String keyword) {
        this.keyword = keyword;
    }

    public Integer getL2CategoryId() {
        return l2CategoryId;
    }

    public void setL2CategoryId(Integer l2CategoryId) {
        this.l2CategoryId = l2CategoryId;
    }

    public String getGridId() {
        return gridId;
    }

    public void setGridId(String gridId) {
        this.gridId = gridId;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public Long getHandlerId() {
        return handlerId;
    }

    public void setHandlerId(Long handlerId) {
        this.handlerId = handlerId;
    }

    public LocalDateTime getHandledAt() {
        return handledAt;
    }

    public void setHandledAt(LocalDateTime handledAt) {
        this.handledAt = handledAt;
    }

    public String getRemark() {
        return remark;
    }

    public void setRemark(String remark) {
        this.remark = remark;
    }

    public LocalDateTime getTriggeredAt() {
        return triggeredAt;
    }

    public void setTriggeredAt(LocalDateTime triggeredAt) {
        this.triggeredAt = triggeredAt;
    }
}
