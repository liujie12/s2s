/**
 * AI 域。
 *
 * <p>职责：AI 能力（禁发类目识别等；发布预检敏感词 {@code 40901}、图片驳回
 * {@code 40902} 等错误码归本域语义）。<b>Batch1 空包</b>——本批次不实现
 * 任何类，仅按详设 §1.2 建包占位；与前端 {@code lib/features/ai/}
 * 同名同构。</p>
 *
 * <p>出处：详设 §1.2（包结构清单：cert/ai 为 Batch1 空包）、§5.4（输入校验）。</p>
 */
package com.s2s.server.ai;
