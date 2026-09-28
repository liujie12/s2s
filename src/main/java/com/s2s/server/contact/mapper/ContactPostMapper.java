package com.s2s.server.contact.mapper;

import java.util.Map;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 联系域对 {@code post} 表的读取 Mapper（[128]）。
 *
 * <p><b>为什么 contact 域自己读 {@code post} 而不调 post 域的 service</b>：
 * 本查询要取的是 {@code contact_value_enc}（AEAD 密文）与 {@code key_version}——
 * 详设 §4.3 与 §5.5.1 把「解密入口收敛」定为全系统安全红线，若在 post 域
 * service 上开一个「返回密文」的公开方法，等于把密文出口从唯一解密点扩大到
 * 另一个域的通用读路径。方式对齐 {@code map} 域既有先例
 * （{@code MapPostMapper} 自有 mapper 直读 {@code post} 做覆盖索引查询，
 * 见 {@code resources/mapper/MapPostMapper.xml}）：<b>域间禁调对方 mapper 的纪律
 * 约束的是「不得注入别人的 mapper」，不是「不得读同一张表」</b>。</p>
 *
 * <p>本 Mapper 只读不写，且只出六列——绝不 {@code SELECT *}（避免把
 * {@code address} 等敏感列顺手带出进程）。</p>
 */
@Mapper
public interface ContactPostMapper {

    /**
     * 取帖子的联系方式密文材料与可见性判定所需的字段。
     *
     * <p>可见性（{@code status}）在 Java 侧经 {@code PostStatus#isGoneForOthers} 判定，
     * 不在 SQL 里写 {@code status = 'active'} 条件——状态口径的唯一落点是
     * {@code PostStatus}（编码规范 §1.1「口径单源、方言单源」）。</p>
     *
     * @param postId 帖子 ID
     * @return {@link Map} 六列：{@code id} / {@code user_id} / {@code contact_channel} /
     *         {@code contact_value_enc}（{@code byte[]}）/ {@code key_version} /
     *         {@code status}；帖子不存在时返回 {@code null}
     */
    Map<String, Object> selectContactRow(@Param("postId") Long postId);
}
