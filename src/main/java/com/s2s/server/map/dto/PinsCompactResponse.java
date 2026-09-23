package com.s2s.server.map.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 地图图钉紧凑响应（[126]；对应 openapi {@code PinsCompactResponse}，GET /map/pins 出参）。
 *
 * <p>为压体积采用 <b>schema + 二维数组</b> 的紧凑格式而非常规对象数组：{@code pins}
 * 每行列序固定为 {@code ["id","lng","lat","category_id","type","completeness_level"]}，
 * 客户端按 {@link #schema()} 声明的列序解析。{@code type} 编码 0=resource / 1=demand；
 * {@code completeness_level} 为 0/1/2。</p>
 *
 * <p>{@code mode=pin} 时 {@code pins} 有值、{@code clusters} 为 null；{@code mode=cluster}
 * 时相反（服务端预聚合，客户端只渲染）。模式由 zoom 换算 metersPerPixel 与
 * {@code NfrPerf.CLUSTER_MODE_SWITCH_METERS_PER_PIXEL} 比较决定（按 zoom 非点数）。</p>
 *
 * @param mode                 聚合模式：{@code pin} / {@code cluster}
 * @param schema               pins 的列序声明，固定 6 列
 * @param pins                 紧凑二维数组，仅 mode=pin 时有值
 * @param clusters             服务端预聚合结果，仅 mode=cluster 时有值
 * @param total                命中总数（可能大于返回条数上限）
 * @param categoryVersionStale 客户端分类树版本是否过期（true 时客户端异步拉树并清空 Pin 缓存）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PinsCompactResponse(
        String mode,
        List<String> schema,
        List<List<Object>> pins,
        List<ClusterItem> clusters,
        Integer total,
        Boolean categoryVersionStale) {
}
