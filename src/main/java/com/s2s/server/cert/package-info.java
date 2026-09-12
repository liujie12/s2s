/**
 * 实名认证域。
 *
 * <p>职责：实名认证（身份证 Batch1 只存 {@code id_card_hash} +
 * {@code id_card_last4}，不存完整明文）。<b>Batch1 空包</b>——本批次不实现
 * 任何类，仅按详设 §1.2 建包占位；与前端 {@code lib/features/cert/}
 * 同名同构。</p>
 *
 * <p>出处：详设 §1.2（包结构清单：cert/ai 为 Batch1 空包）、安全 §4。</p>
 */
package com.s2s.server.cert;
