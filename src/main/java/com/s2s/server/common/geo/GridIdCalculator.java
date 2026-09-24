package com.s2s.server.common.geo;

/**
 * grid_id 计算器（[125]；详设 §5.4.1「三方逐位一致」）。
 *
 * <p>职责：把 GCJ-02 经纬度转为约 500m 网格 ID（{@code "gx_gy"}），客户端 Dart /
 * 服务端 Java / SQL 三方逐位一致。落 {@code post.grid_id varchar(24)}。</p>
 *
 * <p>算法（整数微度域，避免浮点累积误差）：
 * <ol>
 *   <li>坐标向下取整到 5 位小数：{@code floor(x * 100000) / 100000}；</li>
 *   <li>转整数微度（1 微度 = 1e-5 度）；</li>
 *   <li>以 0.0045°（450 微度）为步长，{@code floor}（向负无穷）取整；</li>
 *   <li>编码 {@code "{gx}_{gy}"}。</li>
 * </ol>
 * </p>
 *
 * <p><b>第 9 条测试向量是唯一能暴露「用截断代替 floor」的探针</b>：
 * 负数场景下 {@code (long)} 是向零截断，会让 -0.000015 落到 0 而非 -1，
 * 故 {@link #floorToMicroDegree} 必须用 {@code Math.floor}。</p>
 */
public final class GridIdCalculator {

    /** 微度换算比例：1 度 = 100000 微度。 */
    private static final double MICRO_DEGREE_SCALE = 100_000d;

    /** 网格步长（微度）：0.0045° = 450 微度 ≈ 500m。 */
    private static final int STEP_MICRO = 450;

    /**
     * 浮点补偿量：补偿 {@code deg * 100000} 的二进制舍入误差。如 {@code 0.00450} 的
     * double 表示略小于 0.0045，乘积得 449.99999999999994，直接 floor 会误得 449；
     * 加本量后得 450，floor 正确。量级远小于 1 微度（1e-5），不影响真实边界判定。
     */
    private static final double FLOOR_EPSILON = 1e-9;

    /**
     * 工具类：禁止实例化。
     */
    private GridIdCalculator() {
        throw new AssertionError("GridIdCalculator 是工具类，不可实例化");
    }

    /**
     * 计算约 500m 网格的 grid_id。
     *
     * @param lng GCJ-02 经度
     * @param lat GCJ-02 纬度
     * @return 形如 {@code "26700_6728"} 的网格标识，落 {@code varchar(24)}
     */
    public static String of(double lng, double lat) {
        long gx = Math.floorDiv(floorToMicroDegree(lng), STEP_MICRO);
        long gy = Math.floorDiv(floorToMicroDegree(lat), STEP_MICRO);
        return gx + "_" + gy;
    }

    /**
     * 将度数向下取整到 5 位小数并转为整数微度（1 微度 = 1e-5 度）。
     *
     * <p>必须用 {@code Math.floor} 而非强制类型转换：负数场景下 {@code (long)}
     * 是向零截断，会让 -0.000015 落到 0 而不是 -1（与测试向量第 9 条冲突）。</p>
     *
     * <p>包级私有（非 private）：供测试断言中间微度值——第 9 条向量最终 grid 仍是
     * {@code -1_-1}（结果偶然正确），必须断言中间值才能暴露「截断代替 floor」。</p>
     *
     * @param deg 度数
     * @return 向下取整到 5 位小数的整数微度值
     */
    static long floorToMicroDegree(double deg) {
        return (long) Math.floor(deg * MICRO_DEGREE_SCALE + FLOOR_EPSILON);
    }
}
