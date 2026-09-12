/**
 * 加解密包。
 *
 * <p>职责：承载 {@code CryptoFacade}（全系统唯一解密入口，Batch1 调用点 == 1，
 * 仅 {@code ContactService#viewContact}）与 {@code BlindIndex}（HMAC-SHA256
 * + pepper 盲索引）、{@code AeadCipher}（AES-GCM-256 随机 IV + AAD 绑定）
 * 两个唯一加解密原语。双列范式：{@code xxx_hash BINARY(32)} +
 * {@code xxx_enc VARBINARY} + {@code key_version TINYINT}。</p>
 *
 * <p>出处：详设 §4（加解密）、安全 §4、§1.2（包结构清单）。</p>
 *
 * <p>落地说明：组件随条目 [125] 落地，本条目（U-2）仅建包占位。</p>
 */
package com.s2s.server.common.crypto;
