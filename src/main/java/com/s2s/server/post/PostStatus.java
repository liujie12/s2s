package com.s2s.server.post;

import java.util.List;

/**
 * post 状态机口径的唯一落点（[127]；2026-09-24 用户裁定「库为真源 + {@code status_reason}
 * 派生」）。
 *
 * <p><b>两套取值不同名，映射只在本类完成</b>：
 * <ul>
 *   <li>库内 {@code post.status} ∈ {@code draft/active/archived/hidden}
 *       （DDL V1:182 表注释「状态机：draft/active/archived/hidden」）；</li>
 *   <li>对外 openapi {@code PostStatusEnum} ∈ {@code active/offline/expired/archived}。</li>
 * </ul>
 * 两者不是同一套取值，映射依据是 {@code (status, status_reason)} 二元组——{@code status_reason}
 * 本就是「进入非 active 路径」的归因列（DDL V1:183），故用它区分 {@code archived} 的进入路径。
 * 禁在 controller / SQL / 客户端各写一份对照（编码规范 §1.1、§1.2）。</p>
 *
 * <p><b>Batch1 不变量</b>：服务端不写 {@code draft}（PRD §8.7「草稿每编辑 3 秒自动存本地」，
 * 草稿是纯客户端概念，{@code POST /posts} 落库即 {@code active}）。故映射遇到 {@code draft}
 * 属状态机破改，按 fail-fast 抛异常而非静默给一个对外值（静默取值会让「有草稿流落库」
 * 看起来一切正常）。</p>
 */
public final class PostStatus {

    /** 库内值：草稿（Batch1 服务端不应出现，见类注释）。 */
    public static final String DB_DRAFT = "draft";

    /** 库内值：在架。 */
    public static final String DB_ACTIVE = "active";

    /** 库内值：已归档（含用户下架、到期、审核下架、成交四条进入路径）。 */
    public static final String DB_ARCHIVED = "archived";

    /** 库内值：已隐藏（发布满 24h 仍未实名的自动隐藏）。 */
    public static final String DB_HIDDEN = "hidden";

    /** {@code status_reason}：用户主动下架。 */
    public static final int REASON_USER_ARCHIVE = 0;

    /** {@code status_reason}：到期自动下架。 */
    public static final int REASON_EXPIRE = 1;

    /** {@code status_reason}：审核下架。 */
    public static final int REASON_AUDIT_TAKEDOWN = 2;

    /** {@code status_reason}：成交。 */
    public static final int REASON_DEAL_DONE = 3;

    /** API 值：在架。 */
    public static final String API_ACTIVE = "active";

    /** API 值：已下架（用户主动下架 / 审核下架 / 24h 未实名隐藏）。 */
    public static final String API_OFFLINE = "offline";

    /** API 值：已过期（到期自动下架）。 */
    public static final String API_EXPIRED = "expired";

    /** API 值：已归档（成交）。 */
    public static final String API_ARCHIVED = "archived";

    /** 变更动作：下架（openapi {@code action=offline}）。 */
    public static final String ACTION_OFFLINE = "offline";

    /** 变更动作：重新上架（openapi {@code action=republish}）。 */
    public static final String ACTION_REPUBLISH = "republish";

    /** 变更动作：延期（openapi {@code action=renew}）。 */
    public static final String ACTION_RENEW = "renew";

    /**
     * 工具类：禁止实例化。
     */
    private PostStatus() {
        throw new AssertionError("PostStatus 是常量类，不可实例化");
    }

    /**
     * 把库内 {@code (status, status_reason)} 派生为对外 API 值。
     *
     * <p>派生表（[127] 裁定后落库口径，已回写后端详设 §5.3.3）：</p>
     * <table>
     *   <tr><th>库内</th><th>API 值</th></tr>
     *   <tr><td>{@code active}</td><td>{@code active}</td></tr>
     *   <tr><td>{@code archived} + reason 0（用户下架）/ 2（审核下架）/ NULL</td>
     *       <td>{@code offline}</td></tr>
     *   <tr><td>{@code archived} + reason 1（到期）</td><td>{@code expired}</td></tr>
     *   <tr><td>{@code archived} + reason 3（成交）</td><td>{@code archived}</td></tr>
     *   <tr><td>{@code hidden}</td><td>{@code offline}</td></tr>
     * </table>
     *
     * @param dbStatus     库内状态（{@link #DB_ACTIVE} 等）
     * @param statusReason 进入非 active 路径的归因（{@code active} 时为 {@code null}）
     * @return {@link String} API 状态值（{@link #API_ACTIVE} 等）
     * @throws IllegalStateException 库内状态为 {@code draft} 或未知值时抛出（Batch1 不变量破改）
     */
    public static String toApi(String dbStatus, Integer statusReason) {
        if (DB_ACTIVE.equals(dbStatus)) {
            return API_ACTIVE;
        }
        if (DB_ARCHIVED.equals(dbStatus)) {
            if (statusReason == null) {
                // 归因缺失按「用户下架」呈现：offline 与 expired/archived 的差异对用户
                // 只影响文案，不泄露路径信息；此处不猜 expired（到期才有 reason=1）。
                return API_OFFLINE;
            }
            return switch (statusReason) {
                case REASON_EXPIRE -> API_EXPIRED;
                case REASON_DEAL_DONE -> API_ARCHIVED;
                default -> API_OFFLINE;
            };
        }
        if (DB_HIDDEN.equals(dbStatus)) {
            return API_OFFLINE;
        }
        throw new IllegalStateException("未知或 Batch1 不应出现的 post.status: " + dbStatus);
    }

    /**
     * 判断该库内状态对「非本人」是否已不可见（详情接口据此回 {@code 41001}）。
     *
     * @param dbStatus 库内状态
     * @return boolean；{@code false} 表示已下架/过期/归档/隐藏（对他人不可见）
     */
    public static boolean isGoneForOthers(String dbStatus) {
        return !DB_ACTIVE.equals(dbStatus);
    }

    /**
     * 判断动作是否为 openapi 声明的合法值。
     *
     * @param action 动作字符串
     * @return boolean；三者之一为 {@code true}
     */
    public static boolean isValidAction(String action) {
        return ACTION_OFFLINE.equals(action)
                || ACTION_REPUBLISH.equals(action)
                || ACTION_RENEW.equals(action);
    }

    /**
     * 「我的发布」按 API 状态筛选时对应的库内条件包（{@code GET /posts/mine?status=}）。
     *
     * <p>为什么用条件包而不是拼 SQL 串：本类只描述「API 值 → 库内 (status, reason) 集合」，
     * 具体 SQL 形态留给 mapper XML——口径单源（本类），方言单源（XML）。</p>
     *
     * @param dbStatuses      允许的库内 status 集合
     * @param reasons         允许的 {@code status_reason} 集合；空集合表示不限归因
     * @param allowNullReason 是否额外放行 {@code status_reason IS NULL} 的行
     */
    public record ApiStatusFilter(List<String> dbStatuses, List<Integer> reasons,
            boolean allowNullReason) {
    }

    /**
     * 把 API 状态筛选值翻成库内条件包（{@link #toApi} 的逆映射）。
     *
     * @param apiStatus API 状态值（{@link #API_ACTIVE} 等）；{@code null} 表示不筛选
     * @return {@link ApiStatusFilter}；{@code apiStatus} 为 {@code null} 时返回
     *         {@code null}（调用方据此跳过筛选条件）
     * @throws IllegalStateException 传入非 openapi 枚举值时抛出（参数校验应在 controller
     *         层先完成，此处是开发期守门）
     */
    public static ApiStatusFilter filterFor(String apiStatus) {
        if (apiStatus == null) {
            return null;
        }
        return switch (apiStatus) {
            case API_ACTIVE -> new ApiStatusFilter(List.of(DB_ACTIVE), List.of(), false);
            case API_OFFLINE -> new ApiStatusFilter(
                    List.of(DB_HIDDEN, DB_ARCHIVED),
                    List.of(REASON_USER_ARCHIVE, REASON_AUDIT_TAKEDOWN),
                    true);
            case API_EXPIRED -> new ApiStatusFilter(
                    List.of(DB_ARCHIVED), List.of(REASON_EXPIRE), false);
            case API_ARCHIVED -> new ApiStatusFilter(
                    List.of(DB_ARCHIVED), List.of(REASON_DEAL_DONE), false);
            default -> throw new IllegalStateException("未知的 API 状态筛选值: " + apiStatus);
        };
    }
}
