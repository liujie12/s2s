/**
 * 埋点域。
 *
 * <p>职责：{@code POST /track/events} 批次落库。固定写法
 * {@code INSERT INTO track_event_YYYYMM (...) VALUES (...) ON DUPLICATE KEY
 * UPDATE id = id}（严禁 {@code INSERT IGNORE}）；{@code ts} 用客户端上报值，
 * 按 {@code ts} 归月表。强制登录态、{@code user_id} 只取登录态、
 * 60 请求/min、单请求 ≤50 事件，超限 {@code 42906}。
 * <b>track 无 entity</b>（详设 §1.2 定案），域内分层为
 * {@code controller/service/mapper/dto}。与前端
 * {@code lib/features/track/} 同名同构。</p>
 *
 * <p>出处：详设 §1.2（包结构清单：map/track 无 entity）、§5.8（埋点落库）、
 * §3.4（埋点限频）。</p>
 *
 * <p>持久层路由（[129] 定案 A′）：本域 Mapper 写埋点库 {@code s2s_track}，<b>不经</b>启动类
 * 主 {@code @MapperScan}（该包已被 {@code excludeFilters} 排除，否则会被绑到 @Primary 的
 * 业务库数据源），而由独立会话承载 —— 见 {@code TrackPersistenceConfig}（自持
 * {@code SqlSessionFactory}，不注册为 bean）与 {@code TrackPersistence}（取 Mapper 的唯一入口）。
 * 之所以自持：MyBatis-Plus 自动装配的工厂方法是 {@code @ConditionalOnMissingBean}，多出
 * {@code SqlSessionFactory}/{@code SqlSessionTemplate} 类型 bean 会让业务库工厂整体退让。</p>
 */
package com.s2s.server.track;
