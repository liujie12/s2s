/**
 * 地理位置服务模块
 * 提供高精度距离计算、地理围栏和地址解析功能
 */

/**
 * 计算两点之间的距离（使用Haversine公式，误差小于100米）
 * @param {number} lat1 - 第一个点的纬度
 * @param {number} lon1 - 第一个点的经度
 * @param {number} lat2 - 第二个点的纬度
 * @param {number} lon2 - 第二个点的经度
 * @returns {number} 两点之间的距离（单位：米）
 */
function calculateDistance(lat1, lon1, lat2, lon2) {
    const R = 6371e3; // 地球半径（单位：米）
    const φ1 = (lat1 * Math.PI) / 180;
    const φ2 = (lat2 * Math.PI) / 180;
    const Δφ = ((lat2 - lat1) * Math.PI) / 180;
    const Δλ = ((lon2 - lon1) * Math.PI) / 180;

    const a =
        Math.sin(Δφ / 2) * Math.sin(Δφ / 2) +
        Math.cos(φ1) * Math.cos(φ2) * Math.sin(Δλ / 2) * Math.sin(Δλ / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

    return R * c;
}

/**
 * 格式化距离显示
 * @param {number} distance - 距离（单位：米）
 * @returns {string} 格式化后的距离字符串
 */
function formatDistance(distance) {
    if (distance < 1000) {
        return `${Math.round(distance)}m`;
    } else {
        return `${(distance / 1000).toFixed(1)}km`;
    }
}

/**
 * 地理围栏类
 */
class GeoFence {
    /**
     * 创建地理围栏
     * @param {Array} coordinates - 围栏坐标数组，格式：[[经度, 纬度], [经度, 纬度], ...]
     * @param {string} name - 围栏名称
     */
    constructor(coordinates, name) {
        this.coordinates = coordinates;
        this.name = name;
    }

    /**
     * 检查点是否在围栏内（使用射线法）
     * @param {number} lon - 点的经度
     * @param {number} lat - 点的纬度
     * @returns {boolean} 点是否在围栏内
     */
    containsPoint(lon, lat) {
        let inside = false;
        const n = this.coordinates.length;

        for (let i = 0, j = n - 1; i < n; j = i++) {
            const xi = this.coordinates[i][0], yi = this.coordinates[i][1];
            const xj = this.coordinates[j][0], yj = this.coordinates[j][1];

            const intersect = 
                ((yi > lat) !== (yj > lat)) && 
                (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi);

            if (intersect) {
                inside = !inside;
            }
        }

        return inside;
    }

    /**
     * 检查点是否在围栏的指定距离内
     * @param {number} lon - 点的经度
     * @param {number} lat - 点的纬度
     * @param {number} distance - 距离阈值（单位：米）
     * @returns {boolean} 点是否在围栏的指定距离内
     */
    isPointNearby(lon, lat, distance) {
        // 检查点是否在围栏内
        if (this.containsPoint(lon, lat)) {
            return true;
        }

        // 检查点是否靠近围栏边界
        const n = this.coordinates.length;
        for (let i = 0, j = n - 1; i < n; j = i++) {
            const xi = this.coordinates[i][0], yi = this.coordinates[i][1];
            const xj = this.coordinates[j][0], yj = this.coordinates[j][1];

            // 计算点到线段的距离
            const segmentDistance = this.pointToSegmentDistance(
                lon, lat, xi, yi, xj, yj
            );

            if (segmentDistance <= distance) {
                return true;
            }
        }

        return false;
    }

    /**
     * 计算点到线段的距离
     * @param {number} x - 点的经度
     * @param {number} y - 点的纬度
     * @param {number} x1 - 线段起点的经度
     * @param {number} y1 - 线段起点的纬度
     * @param {number} x2 - 线段终点的经度
     * @param {number} y2 - 线段终点的纬度
     * @returns {number} 点到线段的距离（单位：米）
     */
    pointToSegmentDistance(x, y, x1, y1, x2, y2) {
        // 计算线段的向量
        const A = x - x1;
        const B = y - y1;
        const C = x2 - x1;
        const D = y2 - y1;

        const dot = A * C + B * D;
        const lenSq = C * C + D * D;
        let param = -1;

        if (lenSq !== 0) {
            param = dot / lenSq;
        }

        let xx, yy;

        if (param < 0) {
            xx = x1;
            yy = y1;
        } else if (param > 1) {
            xx = x2;
            yy = y2;
        } else {
            xx = x1 + param * C;
            yy = y1 + param * D;
        }

        return calculateDistance(y, x, yy, xx);
    }
}

/**
 * 地址解析和坐标转换服务
 */
class GeocodingService {
    constructor() {
        this.cache = new Map();
        this.cacheSize = 100; // 缓存大小限制
    }

    /**
     * 通过地址获取坐标（模拟实现，实际项目中应调用真实的地理编码服务）
     * @param {string} address - 地址字符串
     * @returns {Promise<Array>} 坐标数组 [经度, 纬度]
     */
    async geocode(address) {
        // 检查缓存
        const cacheKey = `geocode_${address}`;
        if (this.cache.has(cacheKey)) {
            return this.cache.get(cacheKey);
        }

        // 模拟地理编码服务
        // 实际项目中应调用高德地图、百度地图等地理编码API
        return new Promise((resolve) => {
            setTimeout(() => {
                // 模拟一些常见地址的坐标
                const mockCoordinates = {
                    '北京市朝阳区': [116.486408, 39.994344],
                    '上海市浦东新区': [121.506377, 31.245105],
                    '广州市天河区': [113.330643, 23.135023],
                    '深圳市南山区': [113.937805, 22.545376],
                    '杭州市西湖区': [120.133476, 30.242711]
                };

                let coordinates;
                if (mockCoordinates[address]) {
                    coordinates = mockCoordinates[address];
                } else {
                    // 随机生成一个坐标（模拟）
                    coordinates = [
                        116.0 + Math.random() * 1.0, // 经度
                        39.8 + Math.random() * 0.5   // 纬度
                    ];
                }

                // 缓存结果
                this._addToCache(cacheKey, coordinates);
                resolve(coordinates);
            }, 300); // 模拟网络延迟
        });
    }

    /**
     * 通过坐标获取地址（模拟实现，实际项目中应调用真实的逆地理编码服务）
     * @param {number} lon - 经度
     * @param {number} lat - 纬度
     * @returns {Promise<string>} 地址字符串
     */
    async reverseGeocode(lon, lat) {
        // 检查缓存
        const cacheKey = `reverse_${lon}_${lat}`;
        if (this.cache.has(cacheKey)) {
            return this.cache.get(cacheKey);
        }

        // 模拟逆地理编码服务
        return new Promise((resolve) => {
            setTimeout(() => {
                // 模拟一些坐标对应的地址
                let address = '未知地址';

                // 检查是否靠近模拟的城市中心
                const cities = [
                    { name: '北京市朝阳区', lon: 116.486408, lat: 39.994344 },
                    { name: '上海市浦东新区', lon: 121.506377, lat: 31.245105 },
                    { name: '广州市天河区', lon: 113.330643, lat: 23.135023 },
                    { name: '深圳市南山区', lon: 113.937805, lat: 22.545376 },
                    { name: '杭州市西湖区', lon: 120.133476, lat: 30.242711 }
                ];

                for (const city of cities) {
                    const distance = calculateDistance(lat, lon, city.lat, city.lon);
                    if (distance < 5000) { // 5公里内
                        address = city.name;
                        break;
                    }
                }

                // 缓存结果
                this._addToCache(cacheKey, address);
                resolve(address);
            }, 300); // 模拟网络延迟
        });
    }

    /**
     * 添加到缓存
     * @param {string} key - 缓存键
     * @param {any} value - 缓存值
     * @private
     */
    _addToCache(key, value) {
        if (this.cache.size >= this.cacheSize) {
            // 移除最早的缓存项
            const firstKey = this.cache.keys().next().value;
            this.cache.delete(firstKey);
        }
        this.cache.set(key, value);
    }

    /**
     * 清空缓存
     */
    clearCache() {
        this.cache.clear();
    }
}

/**
 * 计算多边形的中心点
 * @param {Array} coordinates - 多边形坐标数组，格式：[[经度, 纬度], [经度, 纬度], ...]
 * @returns {Array} 中心点坐标 [经度, 纬度]
 */
function calculatePolygonCenter(coordinates) {
    let x = 0, y = 0;
    const n = coordinates.length;

    for (const coord of coordinates) {
        x += coord[0];
        y += coord[1];
    }

    return [x / n, y / n];
}

/**
 * 计算矩形边界框
 * @param {Array} coordinates - 坐标数组，格式：[[经度, 纬度], [经度, 纬度], ...]
 * @returns {Object} 边界框对象 {minLon, minLat, maxLon, maxLat}
 */
function calculateBoundingBox(coordinates) {
    let minLon = Infinity, minLat = Infinity;
    let maxLon = -Infinity, maxLat = -Infinity;

    for (const coord of coordinates) {
        minLon = Math.min(minLon, coord[0]);
        minLat = Math.min(minLat, coord[1]);
        maxLon = Math.max(maxLon, coord[0]);
        maxLat = Math.max(maxLat, coord[1]);
    }

    return { minLon, minLat, maxLon, maxLat };
}

// 导出模块
const geolocationService = {
    calculateDistance,
    formatDistance,
    GeoFence,
    GeocodingService,
    calculatePolygonCenter,
    calculateBoundingBox
};

// 全局变量，方便其他脚本使用
if (typeof window !== 'undefined') {
    window.geolocationService = geolocationService;
}
