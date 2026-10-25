package com.s2s.server.search;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.baomidou.mybatisplus.core.conditions.update.UpdateWrapper;
import com.s2s.server.common.constants.NfrSearch;
import com.s2s.server.post.entity.PostEntity;
import com.s2s.server.post.mapper.PostMapper;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.ApplicationContext;
import org.springframework.stereotype.Component;

/**
 * 存量帖子小区回填（一次性运维任务）。
 *
 * <p><b>为什么需要</b>：`post.community_id` 是 V19 新增列，历史帖子全部为空；
 * 不做回填，「北城新徽苑」这类小区精确过滤只能命中新发布的帖子。</p>
 *
 * <p><b>怎么触发</b>：仅在显式传入 `--backfill.community=true` 时装配。
 * 任务跑完主动退出进程，不会挂在常驻服务里。</p>
 *
 * <p><b>安全边界</b>：只更新 `community_id IS NULL` 的行（条件更新），
 * 不覆盖并发写入；高德无结果/未配置 Key 时保持空值，可下次重跑。</p>
 */
@Component
@ConditionalOnProperty(name = "backfill.community", havingValue = "true")
public class CommunityBackfillRunner implements ApplicationRunner {

    /** 日志。 */
    private static final Logger LOG = LoggerFactory.getLogger(CommunityBackfillRunner.class);

    /** 本次最多处理的帖子数（0 表示不限制，由调用方显式给出）。 */
    @Value("${backfill.community.limit:0}")
    private int limit;

    private final PostMapper postMapper;
    private final CommunityResolver communityResolver;
    private final AmapPoiClient amapPoiClient;
    private final ApplicationContext applicationContext;

    /**
     * 构造回填任务。
     *
     * @param postMapper         帖子 Mapper
     * @param communityResolver  小区实体归一
     * @param amapPoiClient      高德客户端（逆地理取城市 adcode）
     * @param applicationContext Spring 上下文（用于退出）
     */
    public CommunityBackfillRunner(PostMapper postMapper,
            CommunityResolver communityResolver,
            AmapPoiClient amapPoiClient,
            ApplicationContext applicationContext) {
        this.postMapper = postMapper;
        this.communityResolver = communityResolver;
        this.amapPoiClient = amapPoiClient;
        this.applicationContext = applicationContext;
    }

    /**
     * 执行回填并退出进程。
     *
     * @param args 启动参数（未使用）
     */
    @Override
    public void run(ApplicationArguments args) {
        long cursor = 0L;
        int processed = 0;
        int updated = 0;
        try {
            while (limit <= 0 || processed < limit) {
                int batchSize = limit <= 0
                        ? NfrSearch.BACKFILL_BATCH_SIZE
                        : Math.min(NfrSearch.BACKFILL_BATCH_SIZE, limit - processed);
                List<PostEntity> batch = postMapper.selectList(new QueryWrapper<PostEntity>()
                        .gt("id", cursor)
                        .isNull("community_id")
                        .isNotNull("address")
                        .ne("address", "")
                        .orderByAsc("id")
                        .last("LIMIT " + batchSize));
                if (batch.isEmpty()) {
                    break;
                }
                for (PostEntity post : batch) {
                    cursor = post.getId();
                    processed++;
                    try {
                        if (fillOne(post)) {
                            updated++;
                        }
                    } catch (RuntimeException exception) {
                        LOG.warn("小区回填单条失败，跳过：postId={}, error={}",
                                post.getId(), exception.getClass().getSimpleName());
                    }
                    Thread.sleep(NfrSearch.BACKFILL_DELAY_MILLIS);
                }
                LOG.info("小区回填进度：processed={}, updated={}, cursor={}", processed, updated, cursor);
                if (batch.size() < batchSize) {
                    break;
                }
            }
            LOG.info("小区回填完成：processed={}, updated={}", processed, updated);
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            LOG.warn("小区回填被中断：processed={}, updated={}", processed, updated);
        } finally {
            int code = SpringApplication.exit(applicationContext, () -> 0);
            System.exit(code);
        }
    }

    /**
     * 解析并回填单条帖子。
     *
     * @param post 帖子实体
     * @return boolean 是否写入成功
     */
    private boolean fillOne(PostEntity post) {
        String address = post.getAddress();
        if (address == null || address.isBlank()) {
            return false;
        }
        String cityAdcode = null;
        if (post.getLng() != null && post.getLat() != null) {
            cityAdcode = amapPoiClient.reverseAdcode(
                    post.getLng().doubleValue(), post.getLat().doubleValue());
        }
        CommunityResolver.CommunityMatch match =
                communityResolver.resolve(address, cityAdcode);
        if (match.communityId() == null) {
            return false;
        }
        int rows = postMapper.update(null, new UpdateWrapper<PostEntity>()
                .eq("id", post.getId())
                .isNull("community_id")
                .set("community_id", match.communityId())
                .set("community_name", match.communityName()));
        return rows > 0;
    }
}
