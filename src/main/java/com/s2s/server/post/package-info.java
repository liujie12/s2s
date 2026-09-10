/**
 * 帖子域。
 *
 * <p>职责：发布/编辑/状态流转。{@code post.version} 乐观锁 {@code @Version}；
 * {@code PATCH /posts/{id}/status} 缺 {@code version} 返 {@code 40001}
 * 不兜底，更新 0 行返 {@code 40903}。域内分层固定
 * {@code controller/service/mapper/entity/dto}；与前端
 * {@code lib/features/post/} 同名同构。</p>
 *
 * <p>出处：详设 §1.3（分层与域边界）、§7/§5.8（数据访问）、§1.2（包结构清单）。</p>
 */
package com.s2s.server.post;
