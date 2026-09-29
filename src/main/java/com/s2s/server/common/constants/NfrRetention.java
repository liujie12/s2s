package com.s2s.server.common.constants;

/**
 * 数据保留期常量——<b>服务端单端正源</b>，逐值抄录自《数据库设计文档》§5「保留策略矩阵」
 * （该矩阵逐行对回 PRD §13.4 与架构 §8）。
 *
 * <p><b>为什么不是 Dart 镜像（例外登记）</b>：保留期与清理动作只发生在服务端（定时任务），
 * Dart 端无消费方，故本类以《数据库设计文档》§5 为真源直接抄录。此例外按编码规范 §3.1
 * 登记（同 {@code RateLimitThresholds}、{@code NfrObs} 的服务端单端范式）。</p>
 *
 * <p><b>改动纪律</b>：本类任一常量改动，必须同时改《数据库设计文档》§5 对应行的保留期与
 * PRD §13.4 表格，并回应 {@code RetentionRuleCoverageTest}（该门禁断言注册表 key 与
 * PRD §13.4 逐值相等）；缺一即视为未改。</p>
 *
 * <p>出处：数据库设计文档 §5（保留策略矩阵，9 条）；架构 §8（定时任务执行者）。</p>
 */
public final class NfrRetention {

    /**
     * 私有构造器：常量类禁止实例化（范式同 {@code ErrorCode}）。
     */
    private NfrRetention() {
    }

    /** 埋点事件月表保留天数（架构 §5.4 / §8：整表 drop 超过 90 天的月表，由 40G 盘容量倒推。
     * 注意它<b>不在</b> PRD §13.4 的 9 条保留策略键之列——那 9 条是合规与业务口径，
     * 埋点 90 天是运维口径，两者不共用一个配置）。消费方：埋点月表清理任务。 */
    public static final int TRACK_EVENT_RETENTION_DAYS = 90;

    /** 审计日志保留天数（保留策略键 {@code audit_log_180d}；BRD:268 合规下限，不可随盘容量下调）。
     * 消费方：审计日志清理任务。 */
    public static final int AUDIT_LOG_RETENTION_DAYS = 180;

    /** 取消收藏记录保留天数（保留策略键 {@code favorite_deleted_30d}：软删满 30 天物删，
     * 期间供误删恢复，PRD §8.6 / §8.7）。消费方：收藏记录清理任务。 */
    public static final int FAVORITE_DELETED_RETENTION_DAYS = 30;

    /** 注销冷静期天数（保留策略键 {@code deactivate_7d}：满 7 天未撤回则删除个人数据，
     * PRD §3.7 / §9.7）。消费方：注销清理任务。 */
    public static final int DEACTIVATE_COOLING_DAYS = 7;

    /** 媒体孤儿判定时长（小时）：创建超过该时长仍为 {@code pending} 的 {@code post_media}
     * 连同 OSS 对象一并清理（架构 §5.1 第 7 条 + 详设 §6 任务 #9）。消费方：媒体孤儿清理任务。 */
    public static final int MEDIA_PENDING_TTL_HOURS = 24;

    /** 中转脱敏日志保留天数（保留策略键 {@code transit_log_30d}，PRD §13.4）。
     * <b>当前无消费方</b>：该日志的存储载体在全套设计文档中查无定义（PRD §7.4.2 只写了
     * 联系中转页的脱敏展示行为，可观测 §2 的三类数据中亦无此对象），故清理动作未实现，
     * 详见说明文档 §2.9 待裁定项。常量先落于此，避免将来实现时手敲数字。 */
    public static final int TRANSIT_LOG_RETENTION_DAYS = 30;
}
