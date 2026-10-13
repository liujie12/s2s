package com.s2s.server.ops;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.ops.dto.FollowUpPage;
import com.s2s.server.ops.entity.OpsFollowUpEntity;
import com.s2s.server.ops.mapper.OpsFollowUpMapper;
import java.time.LocalDateTime;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 待运营跟进队列服务（[153] B2-5 ⑥；PRD §6.4.4）。
 *
 * <p><b>职责</b>：承载队列的写入（空圈检索入队）、读取（后台列表）与处理
 * （{@code pending → handled}）。队列是「供给缺口」的运营线索集合——
 * PRD §6.4.4：空圈且 30 秒内三级兜底均无结果 → 该需求进本队列。</p>
 *
 * <p><b>入队触发口径</b>：本工程检索为「单次查询 + 网格按半径扩展」
 * （{@code MapService.expandGridCells}），无独立三级兜底段落，故以
 * <b>检索结果 {@code total == 0}</b> 作为「三级兜底均无结果」的等价触发点
 * —— 由 map 域在检索结束后调用 {@link #enqueue}（2026-10-12 用户裁定）。</p>
 *
 * <p><b>去重口径</b>：DDL 未建唯一键（{@code user_id}/{@code keyword} 可空，
 * MySQL 唯一索引对 NULL 不去重），改由本服务判定「同 user + keyword + l2 已有
 * pending 条目则跳过」——避免同一用户反复空搜把队列刷爆，同时口径显式可测。</p>
 */
@Service
public class OpsFollowUpService {

    /** 处理状态：待跟进。 */
    public static final String STATUS_PENDING = "pending";

    /** 处理状态：已跟进。 */
    public static final String STATUS_HANDLED = "handled";

    /** 队列 Mapper（本域自有）。 */
    private final OpsFollowUpMapper opsFollowUpMapper;

    /**
     * 构造队列服务。
     *
     * @param opsFollowUpMapper 队列 Mapper
     */
    public OpsFollowUpService(OpsFollowUpMapper opsFollowUpMapper) {
        this.opsFollowUpMapper = opsFollowUpMapper;
    }

    /**
     * 入队一条「空圈」线索（已存在同条件的 pending 条目则跳过）。
     *
     * @param userId       触发检索的用户（游客传 {@code null}）
     * @param keyword      检索关键词（可空）
     * @param l2CategoryId 检索的二级类目 ID（可空）
     * @param gridId       坐标网格（可空）
     */
    @Transactional
    public void enqueue(Long userId, String keyword, Integer l2CategoryId, String gridId) {
        if (hasPendingDuplicate(userId, keyword, l2CategoryId)) {
            return;
        }
        OpsFollowUpEntity entity = new OpsFollowUpEntity();
        entity.setUserId(userId);
        entity.setKeyword(keyword);
        entity.setL2CategoryId(l2CategoryId);
        entity.setGridId(gridId);
        entity.setStatus(STATUS_PENDING);
        opsFollowUpMapper.insert(entity);
    }

    /**
     * 分页列出队列（后台用）。
     *
     * @param status   处理状态
     * @param page     页码（1 起）
     * @param pageSize 每页条数
     * @return {@link FollowUpPage} 当前页 + 总数
     */
    public FollowUpPage list(String status, int page, int pageSize) {
        long total = opsFollowUpMapper.countByStatus(status);
        return new FollowUpPage(
                opsFollowUpMapper.selectPageByStatus(status, (page - 1) * pageSize, pageSize),
                total, page, pageSize);
    }

    /**
     * 处理（跟进）一条队列条目。
     *
     * @param id          队列条目 ID
     * @param handlerId   处理人（后台管理员）
     * @param remark      处理备注（可空）
     * @throws BizException 条目不存在 → 41001；已处理 → 40001
     */
    @Transactional
    public void handle(long id, Long handlerId, String remark) {
        OpsFollowUpEntity existing = opsFollowUpMapper.selectById(id);
        if (existing == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        if (!STATUS_PENDING.equals(existing.getStatus())) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        OpsFollowUpEntity patch = new OpsFollowUpEntity();
        patch.setId(id);
        patch.setStatus(STATUS_HANDLED);
        patch.setHandlerId(handlerId);
        patch.setHandledAt(LocalDateTime.now());
        patch.setRemark(remark);
        opsFollowUpMapper.updateById(patch);
    }

    /**
     * 判定是否已存在同条件待跟进条目（去重，见类注释）。
     *
     * @param userId       用户 ID（可空）
     * @param keyword      关键词（可空）
     * @param l2CategoryId 二级类目 ID（可空）
     * @return boolean；存在 pending 同条件条目时 {@code true}
     */
    private boolean hasPendingDuplicate(Long userId, String keyword, Integer l2CategoryId) {
        QueryWrapper<OpsFollowUpEntity> wrapper =
                new QueryWrapper<OpsFollowUpEntity>().eq("status", STATUS_PENDING);
        // 可空列必须用 isNull 显式表达，`= null` 永不命中（会把去重静默变成不去重）
        if (userId == null) {
            wrapper.isNull("user_id");
        } else {
            wrapper.eq("user_id", userId);
        }
        if (keyword == null) {
            wrapper.isNull("keyword");
        } else {
            wrapper.eq("keyword", keyword);
        }
        if (l2CategoryId == null) {
            wrapper.isNull("l2_category_id");
        } else {
            wrapper.eq("l2_category_id", l2CategoryId);
        }
        return opsFollowUpMapper.selectCount(wrapper) > 0;
    }
}
