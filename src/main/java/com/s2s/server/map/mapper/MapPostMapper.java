package com.s2s.server.map.mapper;

import java.util.List;
import java.util.Map;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * map 域只读查询 Mapper（[126]；详设 §5.4.2）。
 *
 * <p>职责：承载 {@code /map/pins} 与 {@code /posts/search} 的性能敏感查询，全部经
 * XML（{@code mapper/MapPostMapper.xml}）实现；{@code post} 表的通用 CRUD 仍在 post 域
 * {@code PostMapper}（MyBatis-Plus {@code BaseMapper}），本类只承载 map 特有的
 * 覆盖索引 SELECT 与列表检索。</p>
 *
 * <p>返回类型统一 {@link Map}（键为列名蛇形），避免为列子集查询预建 POJO
 * （编码规范 §1.1 反冗余）；service 层按列名显式取值并序列化。</p>
 */
@Mapper
public interface MapPostMapper {

    /**
     * 覆盖索引查询：拉取视野内 Pin（{@code mode=pin}）。
     *
     * <p>SELECT 列表固定为 6 列（{@code id/lng/lat/leaf_category_id/type/completeness_level}），
     * 全部落在 {@code idx_pins_cover} 内，达成 index-only scan 不回表。</p>
     *
     * @param gridIds        按半径展开的网格集合（null 表示全城，不加 grid 过滤）
     * @param leafCategoryIds 叶子类目 ID 集合
     * @param type           供需态（resource/demand）
     * @param limit          条数上限（NfrPerf.RENDER_MAX_PINS）
     * @return Pin 行集合（列名：id/lng/lat/leaf_category_id/type/completeness_level）
     */
    List<Map<String, Object>> selectPins(
            @Param("gridIds") List<String> gridIds,
            @Param("leafCategoryIds") List<Integer> leafCategoryIds,
            @Param("type") String type,
            @Param("limit") int limit);

    /**
     * 命中总数（与 {@link #selectPins} 同过滤条件，不设 LIMIT）。
     *
     * @param gridIds        网格集合（null 表示全城）
     * @param leafCategoryIds 叶子类目 ID 集合
     * @param type           供需态
     * @return 命中总数
     */
    long countPins(
            @Param("gridIds") List<String> gridIds,
            @Param("leafCategoryIds") List<Integer> leafCategoryIds,
            @Param("type") String type);

    /**
     * 服务端预聚合：按网格聚簇（{@code mode=cluster}）。
     *
     * @param gridIds        网格集合（null 表示全城）
     * @param leafCategoryIds 叶子类目 ID 集合
     * @param type           供需态
     * @param limit          聚合点上限
     * @return 聚合点行集合（列名：lng/lat/count）
     */
    List<Map<String, Object>> selectClusters(
            @Param("gridIds") List<String> gridIds,
            @Param("leafCategoryIds") List<Integer> leafCategoryIds,
            @Param("type") String type,
            @Param("limit") int limit);

    /**
     * 列表检索候选集（JOIN user，供 service 层排序/分页）。
     *
     * @param gridIds        网格集合（null 表示全城）
     * @param leafCategoryIds 叶子类目 ID 集合
     * @param type           供需态
     * @param keyword        关键词（可空）
     * @return 候选行集合（列名：id/type/leaf_category_id/l2_category_id/title/summary/
     *         lng/lat/completeness_level/publish_at/author_id/nickname/avatar_url/realname_status）
     */
    List<Map<String, Object>> selectSearchPosts(
            @Param("gridIds") List<String> gridIds,
            @Param("leafCategoryIds") List<Integer> leafCategoryIds,
            @Param("type") String type,
            @Param("keyword") String keyword);
}
