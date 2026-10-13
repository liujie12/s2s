package com.s2s.server.ops;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.category.CategoryService;
import com.s2s.server.common.constants.NfrTempCategory;
import com.s2s.server.contact.ContactService;
import com.s2s.server.ops.dto.TempCategoryPage;
import com.s2s.server.ops.dto.TempCategoryView;
import com.s2s.server.ops.entity.TempCategoryEntity;
import com.s2s.server.ops.entity.TempCategoryStatEntity;
import com.s2s.server.ops.mapper.TempCategoryMapper;
import com.s2s.server.ops.mapper.TempCategoryStatMapper;
import com.s2s.server.post.PostQueryService;
import java.time.LocalDateTime;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 72h 临时类目快速验证通道服务（[153] B2-5 §9.10.2；PRD §9.10.2）。
 *
 * <p><b>业务闭环</b>：运营发现新需求 → 经本服务在该 L2 下挂一个临时叶子
 * （落 {@code category} + {@code temp_category}，{@code expire_at = now + 72h}）
 * → 到期由 {@link #settleExpired()} 结算：算窗口内发布数与联系数 → 两者均达标
 * 则 {@code promoted}（进转正候选池），否则 {@code expired} 且置
 * {@code category.forbidden=1}（下线 = 不可再发，而非从树里删除——历史帖仍需可查）。</p>
 *
 * <p><b>域边界</b>（编码规范 §4.2）：临时叶子仍须进分类树（C 端才能发布/检索到它），
 * 故分类树写入经 category 域的 {@link CategoryService}；发布数/联系数分别经
 * post 域 {@link PostQueryService} 与 contact 域 {@link ContactService} 取数——
 * 本域不直连他域 Mapper。</p>
 *
 * <p><b>阈值单源</b>：72h 窗口与达标线（发布 ≥3、联系 ≥5）只在
 * {@link NfrTempCategory} 定义一处（编码规范 §3.1）。</p>
 */
@Service
public class TempCategoryService {

    private static final Logger log = LoggerFactory.getLogger(TempCategoryService.class);

    /** 生命周期：验证中。 */
    public static final String STATUS_ACTIVE = "active";

    /** 生命周期：未达标已下线。 */
    public static final String STATUS_EXPIRED = "expired";

    /** 生命周期：已进转正候选池。 */
    public static final String STATUS_PROMOTED = "promoted";

    /** 禁发标记：禁发（下线临时类目即置此值）。 */
    private static final int FORBIDDEN_YES = 1;

    /** 临时类目 Mapper（本域自有）。 */
    private final TempCategoryMapper tempCategoryMapper;

    /** 判定快照 Mapper（本域自有）。 */
    private final TempCategoryStatMapper tempCategoryStatMapper;

    /** 分类服务（临时叶子落分类树 / 到期下线置 forbidden）。 */
    private final CategoryService categoryService;

    /** post 域读服务（窗口内发布数）。 */
    private final PostQueryService postQueryService;

    /** contact 域服务（窗口内被联系数）。 */
    private final ContactService contactService;

    /**
     * 构造临时类目服务。
     *
     * @param tempCategoryMapper     临时类目 Mapper
     * @param tempCategoryStatMapper 判定快照 Mapper
     * @param categoryService        分类服务（category 域 service 接口）
     * @param postQueryService       post 域读服务（域间取发布数）
     * @param contactService         contact 域服务（域间取联系数）
     */
    public TempCategoryService(TempCategoryMapper tempCategoryMapper,
            TempCategoryStatMapper tempCategoryStatMapper,
            CategoryService categoryService,
            PostQueryService postQueryService,
            ContactService contactService) {
        this.tempCategoryMapper = tempCategoryMapper;
        this.tempCategoryStatMapper = tempCategoryStatMapper;
        this.categoryService = categoryService;
        this.postQueryService = postQueryService;
        this.contactService = contactService;
    }

    /**
     * 创建一个临时叶子类目并开启 72h 验证。
     *
     * <p>先经 {@link CategoryService#createLeaf} 落分类树拿到叶子 ID（编号规则
     * 「L2×100+序号」由 category 域唯一承载），再以同一 ID 落 {@code temp_category}
     * 元数据行；两步<b>同事务</b>——分类树已插入而元数据行缺失会留下一个「永不结算」
     * 的隐式永久临时类目。</p>
     *
     * @param l2ParentId 挂载的「临时」二级类目 ID（须由运营先用分类配置页建好）
     * @param name       临时类目名
     * @param createdBy  创建人（后台 admin_user.id）
     * @return {@link Integer} 新建临时叶子类目 ID
     * @throws com.s2s.server.common.error.BizException 父级不存在或非二级 → 40001
     */
    @Transactional
    public Integer createTempLeaf(int l2ParentId, String name, long createdBy) {
        // 图标/高敏认证/禁发/排序均走默认（可空），与普通叶子一致
        Integer leafId = categoryService.createLeaf(l2ParentId, name, null, null, null, null);

        TempCategoryEntity entity = new TempCategoryEntity();
        entity.setId(leafId);
        entity.setL2ParentId(l2ParentId);
        entity.setName(name);
        entity.setStatus(STATUS_ACTIVE);
        entity.setCreatedBy(createdBy);
        entity.setExpireAt(LocalDateTime.now().plus(NfrTempCategory.VALIDATION_WINDOW));
        tempCategoryMapper.insert(entity);
        return leafId;
    }

    /**
     * 结算所有已到期的临时类目（定时任务调用）。
     *
     * <p>取 {@code status='active' 且 expire_at <= now} 的行，逐条算窗口内发布/联系数，
     * 写判定快照，并把状态置为 {@code promoted} 或 {@code expired}（后者附带
     * {@code category.forbidden=1}）。状态一旦改变即不再被本方法拾取，故天然幂等——
     * 重复调度不会重复结算同一条。</p>
     *
     * <p><b>为什么整批同事务</b>：临时类目由运营手工创建，量级为「个位数子」，
     * 不存在大批量积压；同事务保证「快照 + 状态 + 分类树禁发」三者原子，避免出现
     * 「已判 expired 但分类仍可发」的中间态。若某条结算抛出，整批回滚，下轮重试。</p>
     *
     * @return int 本次结算条数（{@code 0} 表示无到期项）
     */
    @Transactional
    public int settleExpired() {
        LocalDateTime now = LocalDateTime.now();
        List<TempCategoryEntity> due = tempCategoryMapper.selectList(
                new QueryWrapper<TempCategoryEntity>()
                        .eq("status", STATUS_ACTIVE)
                        .le("expire_at", now));
        for (TempCategoryEntity entity : due) {
            settleOne(entity, now);
        }
        return due.size();
    }

    /**
     * 分页列出临时类目（后台用）。
     *
     * @param status   生命周期筛选（{@code null}/空 → 不限）
     * @param page     页码（1 起）
     * @param pageSize 每页条数
     * @return {@link TempCategoryPage} 当前页视图 + 总数
     */
    public TempCategoryPage list(String status, int page, int pageSize) {
        long total = tempCategoryMapper.countByStatus(status);
        List<TempCategoryEntity> rows =
                tempCategoryMapper.selectPageByStatus(status, (page - 1) * pageSize, pageSize);
        Map<Integer, TempCategoryStatEntity> statById = loadStats(rows);
        List<TempCategoryView> items = rows.stream()
                .map(row -> TempCategoryView.of(row, statById.get(row.getId())))
                .toList();
        return new TempCategoryPage(items, total, page, pageSize);
    }

    /**
     * 结算单条临时类目：算数 → 写快照 → 置状态 →（未达标时）禁发。
     *
     * @param entity 到期的临时类目（由 {@link #settleExpired()} 从库内查出，含 created_at）
     * @param now    统一结算时刻（同批共用，避免逐条取时钟造成时刻漂移）
     */
    private void settleOne(TempCategoryEntity entity, LocalDateTime now) {
        long publishCount = postQueryService.countPublishedByLeafBetween(
                entity.getId(), entity.getCreatedAt(), entity.getExpireAt());
        long contactCount = contactService.countContactsByLeafBetween(
                entity.getId(), entity.getCreatedAt(), entity.getExpireAt());
        boolean promoted = publishCount >= NfrTempCategory.PROMOTE_MIN_PUBLISH
                && contactCount >= NfrTempCategory.PROMOTE_MIN_CONTACT;

        TempCategoryStatEntity stat = new TempCategoryStatEntity();
        stat.setTempCategoryId(entity.getId());
        stat.setPublishCount((int) publishCount);
        stat.setContactCount((int) contactCount);
        stat.setPromoted(promoted ? 1 : 0);
        stat.setEvaluatedAt(now);
        tempCategoryStatMapper.insert(stat);

        TempCategoryEntity patch = new TempCategoryEntity();
        patch.setId(entity.getId());
        patch.setStatus(promoted ? STATUS_PROMOTED : STATUS_EXPIRED);
        patch.setClosedAt(now);
        tempCategoryMapper.updateById(patch);

        if (!promoted) {
            categoryService.updateCategory(entity.getId(), null, null, null, FORBIDDEN_YES, null);
        }
        log.info("临时类目结算：id={}, publish={}, contact={}, 结果={}",
                entity.getId(), publishCount, contactCount,
                promoted ? STATUS_PROMOTED : STATUS_EXPIRED);
    }

    /**
     * 批量取当前页的判定快照（一次查询覆盖整页，避免 N+1）。
     *
     * @param rows 当前页临时类目
     * @return {@link Map} 临时类目 ID → 判定快照；无快照的条目不出现
     */
    private Map<Integer, TempCategoryStatEntity> loadStats(List<TempCategoryEntity> rows) {
        if (rows.isEmpty()) {
            return Map.of();
        }
        List<Integer> ids = rows.stream().map(TempCategoryEntity::getId).toList();
        List<TempCategoryStatEntity> stats = tempCategoryStatMapper.selectBatchIds(ids);
        Map<Integer, TempCategoryStatEntity> byId = new HashMap<>();
        for (TempCategoryStatEntity stat : stats) {
            byId.put(stat.getTempCategoryId(), stat);
        }
        return byId;
    }
}
