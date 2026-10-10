package com.s2s.server.track.mapper;

import java.util.List;
import java.util.Map;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 埋点库维护 Mapper（[129] P4；架构 §8 任务 2/3/8；数据库设计 §3.16 / §6.5）。
 *
 * <p>职责：埋点月表的<b>建 / 删 / 枚举</b>与巡检度量（行数、占盘、高位分钟数）。
 * 与 {@link TrackEventMapper}（写事件）分开，因为两者的调用方与风险面完全不同：
 * 前者由上报接口高频调用、只做 DML；本类只由定时任务低频调用、含 <b>DDL</b>
 * （{@code CREATE TABLE ... LIKE} / {@code DROP TABLE}）——把 DDL 与业务写入混在一支
 * Mapper 里，会让「谁有权建表删表」在代码上失去边界。</p>
 *
 * <p><b>DDL 的两条硬纪律</b>（数据库设计 §3.16.1 / §6.5）：</p>
 * <ol>
 *   <li>预建必须 {@code CREATE TABLE ... LIKE}——{@code LIKE} 会连索引一起复制，
 *       逐列拼 DDL 会漏掉 {@code uk_event_dedup}，导致下月去重静默失效；</li>
 *   <li>清理必须整表 {@code DROP}，不得逐行 {@code DELETE}——对千万行表做 DELETE 会
 *       把 buffer pool 与 binlog 一起打满（架构 §8 口径说明）。</li>
 * </ol>
 *
 * <p><b>不经 {@code @MapperScan}</b>：本包被启动类主扫描排除，实例一律经
 * {@code TrackPersistence#mapper(Class)} 取得（同 {@link TrackEventMapper} 说明）。</p>
 *
 * <p><b>表名的可信性</b>：{@code newTable}/{@code templateTable}/{@code tableName} 均由
 * 任务侧按 {@code ^track_event_\d{6}$} 白名单生成或从 {@code information_schema} 回读，
 * 不接受任何外部输入；XML 中以 {@code ${}} 拼接是必要形态（表名不能参数化）。</p>
 */
@Mapper
public interface TrackMaintenanceMapper {

    /**
     * 按月表结构建新表（任务 2：每月 25 日预建下月表）。
     *
     * @param newTable      待建表名（{@code track_event_YYYYMM}）
     * @param templateTable 结构模板表名（已存在的月表；{@code LIKE} 连索引一并复制）
     */
    void createTableLike(@Param("newTable") String newTable,
            @Param("templateTable") String templateTable);

    /**
     * 整表删除过期月表（任务 3：DROP 超 90 天的月表）。
     *
     * @param tableName 待删表名（白名单校验后传入）
     */
    void dropTable(@Param("tableName") String tableName);

    /**
     * 枚举埋点库内的月表名（供清理任务判定过期、供巡检统计行数）。
     *
     * @return {@link List} 月表名（形如 {@code track_event_202609}，按名排序）
     */
    List<String> listMonthTables();

    /**
     * 埋点月表行数合计（任务 8 阈值 T1 的一半）。
     *
     * @return {@link Long} {@code information_schema.TABLES.TABLE_ROWS} 求和（统计值，非精确值）
     */
    Long countEventRows();

    /**
     * 埋点库占盘（GB，任务 8 阈值 T1 的另一半）。
     *
     * <p>只量埋点库：可观测 §9.1 明写「不能用 {@code df}」——{@code df} 量的是整盘，
     * 含系统、镜像、业务库等七项，会在埋点只占 2GB 时误报。</p>
     *
     * @return {@link Double} {@code (DATA_LENGTH + INDEX_LENGTH)} 合计的 GB 数
     */
    Double storageGb();

    /**
     * 统计近 N 天内「每分钟事件数超过阈值」的分钟数（任务 8 阈值 T2）。
     *
     * <p>SQL 形态逐字对齐可观测 §9.1 T2：按 {@code ts}（客户端采集时刻）分分钟聚合，
     * 取 {@code HAVING COUNT(*) > 每分钟阈值} 的分钟数。用 {@code ts} 而非 {@code created_at}：
     * 后者会因跨月回灌或离线积压失真。</p>
     *
     * @param tableName         当月月表名（白名单校验后传入）
     * @param since             统计窗口起点（当前时刻 − 窗口天数，由任务侧算好）
     * @param perMinuteThreshold 单分钟计数阈值（对应 QPS 上限 × 60）
     * @return {@link Long} 处于高位的分钟数（与「持续分钟数阈值」比较后判定是否命中）
     */
    Long countHighVolumeMinutes(@Param("tableName") String tableName,
            @Param("since") java.time.LocalDateTime since,
            @Param("perMinuteThreshold") long perMinuteThreshold);

    /**
     * 在埋点库执行一条 T3 主看板 SQL 并返回结果行（[148]；可观测架构方案 §9.1 T3 / §9.1.1）。
     *
     * <p><b>为什么这里只能整条 {@code ${}} 拼入、而不改写成固定 XML 语句</b>：T3 的判定对象是
     * <b>已交付的单一文件</b> {@code docs/architecture/dashboard_queries.sql}——要逐条计时
     * 「清单里的原句」。把它固化成 XML 语句，就丢掉了「文件改了、判定跟着改」这条唯一对价。
     * 语句来源是<b>打包进镜像的静态文件</b>（非外部输入）；其中的可变片段仅两处，均由任务侧收敛：
     * 月表名由 {@code TrackTableNames} 按 {@code ^track_event_\d{6}$} 生成，重启窗口时刻经
     * {@code yyyy-MM-dd HH:mm:ss} 白名单复校后注入。形态与同域表名 {@code ${tableName}}
     * 同属「拼的是自己生成/校验过的片段」（编码规范 §6「SQL 注入防护：禁 {@code ${}} 接外部输入」）。
     * 调用方另以「仅允许单条 SELECT」兜底：语句被改成非查询即拒绝执行。</p>
     *
     * @param sql 已替换占位符的单条 SELECT 语句（任务侧构造并校验）
     * @return {@link List} 结果行（列名 → 值）；T3 只计时，不消费行内容
     */
    List<Map<String, Object>> executeDashboardQuery(@Param("sql") String sql);
}
