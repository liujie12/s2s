/**
 * 地图域。
 *
 * <p>职责：{@code /map/pins} 聚合查询（缓存键五要素缺任一返 {@code 40001}
 * 不做默认值兜底，上限 500 Pin）。<b>map 无 entity</b>（详设 §1.2 定案），
 * 域内分层为 {@code controller/service/mapper/dto}。与前端
 * {@code lib/features/map/} 同名同构。</p>
 *
 * <p>出处：详设 §1.2（包结构清单：map/track 无 entity）、§5.4（输入校验）。</p>
 */
package com.s2s.server.map;
