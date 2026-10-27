package com.s2s.server.contact;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import com.s2s.server.contact.mapper.PostViewMapper;
import java.time.Clock;
import java.time.LocalDate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 浏览上报服务（openapi {@code POST /posts/{post_id}/view}）。
 *
 * <p><b>口径</b>：同一 viewer 同一业务日只计 1 次；作者本人不计数；
 * 登录上报时合并当日同设备游客行，保证「先游客后登录」同日只计 1。
 * 日计数写入 {@code post_view_daily}，明细只负责去重与保留期清理。</p>
 */
@Service
public class PostViewService {

    /** 登录用户去重键前缀。 */
    private static final String USER_KEY_PREFIX = "user:";

    /** 游客去重键前缀。 */
    private static final String DEVICE_KEY_PREFIX = "device:";

    private final PostViewMapper postViewMapper;
    private final Clock clock;

    /**
     * 构造浏览上报服务（生产时钟：Asia/Shanghai）。
     *
     * <p><b>必须显式 {@code @Autowired}</b>：本类有两个构造器（生产 + 测试注入
     * {@code Clock}），Spring 无法在多个候选间自行选定，缺注解时启动报
     * 「No default constructor found」（2026-10-27 真机冒烟首启实测）。</p>
     *
     * @param postViewMapper 浏览计数 Mapper
     */
    @Autowired
    public PostViewService(PostViewMapper postViewMapper) {
        this(postViewMapper, Clock.system(RateLimitThresholds.ZONE));
    }

    /**
     * 构造浏览上报服务（测试可注入固定时钟）。
     *
     * @param postViewMapper 浏览计数 Mapper
     * @param clock          业务日时钟
     */
    PostViewService(PostViewMapper postViewMapper, Clock clock) {
        this.postViewMapper = postViewMapper;
        this.clock = clock;
    }

    /**
     * 上报一次浏览（幂等：同一 viewer 同一业务日只计 1 次）。
     *
     * @param userId   当前登录用户 ID；游客为 {@code null}
     * @param postId   帖子 ID
     * @param deviceId 设备标识（X-Device-Id）；游客必填，登录用户可空
     * @throws BizException {@code 41001} 帖子不存在 / {@code 40001} 游客缺设备号
     */
    @Transactional
    public void report(Long userId, Long postId, String deviceId) {
        Long ownerId = postViewMapper.selectPostOwner(postId);
        if (ownerId == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        if (userId != null && userId.equals(ownerId)) {
            // 作者本人浏览不计入（先登录后游客无法反推账号，见计划 Assumptions）。
            return;
        }

        LocalDate day = LocalDate.now(clock);
        boolean deviceValid = deviceId != null && RateLimitKeys.isValidDeviceId(deviceId);
        if (userId == null) {
            if (!deviceValid) {
                throw BizException.of(ErrorCode.PARAM_INVALID);
            }
            int inserted = insertViewIfAbsent(postId, DEVICE_KEY_PREFIX + deviceId, day);
            applyDelta(postId, day, inserted);
            return;
        }

        int removed = 0;
        if (deviceValid) {
            removed = postViewMapper.deleteView(postId, DEVICE_KEY_PREFIX + deviceId, day);
        }
        int inserted = insertViewIfAbsent(postId, USER_KEY_PREFIX + userId, day);
        applyDelta(postId, day, inserted - removed);
    }

    /**
     * 插入明细；唯一键冲突视为「已去过重」，返回 0。
     *
     * @param postId    帖子 ID
     * @param viewerKey 去重键
     * @param day       业务日
     * @return int 1＝首次插入；0＝已存在
     */
    private int insertViewIfAbsent(Long postId, String viewerKey, LocalDate day) {
        if (postViewMapper.countView(postId, viewerKey, day) > 0) {
            return 0;
        }
        try {
            return postViewMapper.insertView(postId, viewerKey, day);
        } catch (DuplicateKeyException race) {
            // 并发下两请求同时通过 countView：唯一键兜底，后到者按已去过重处理。
            return 0;
        }
    }

    /**
     * 按净增量更新日计数；增量为 0 时不写。
     *
     * @param postId 帖子 ID
     * @param day    业务日
     * @param delta  净增量（-1 / 0 / 1）
     */
    private void applyDelta(Long postId, LocalDate day, int delta) {
        if (delta != 0) {
            postViewMapper.upsertDaily(postId, day, delta);
        }
    }
}
