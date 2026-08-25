/**
 * 多源定位融合模块
 * 集成GPS、Wi-Fi、蓝牙、基站和IP等多种定位方式，提高定位精度和可靠性
 * 支持动态优先级调整、健康状态监控、错误恢复和精度评估
 */

/**
 * 定位源接口
 * 所有定位源都应实现此接口
 */
class LocationSource {
    /**
     * 获取定位数据
     * @returns {Promise<Object>} 定位数据对象，包含latitude、longitude、accuracy、timestamp等字段
     */
    async getLocation() {
        throw new Error('子类必须实现getLocation方法');
    }

    /**
     * 获取定位源名称
     * @returns {string} 定位源名称
     */
    getName() {
        throw new Error('子类必须实现getName方法');
    }

    /**
     * 获取定位源优先级
     * @returns {number} 优先级，数字越小优先级越高
     */
    getPriority() {
        throw new Error('子类必须实现getPriority方法');
    }

    /**
     * 检查定位源是否可用
     * @returns {boolean} 是否可用
     */
    isAvailable() {
        throw new Error('子类必须实现isAvailable方法');
    }
}

/**
 * GPS定位源
 */
class GPSLocationSource extends LocationSource {
    constructor() {
        super();
        this.name = 'GPS';
        this.priority = 1;
    }

    async getLocation() {
        if (!this.isAvailable()) {
            throw new Error('GPS定位不可用');
        }

        // 检查权限管理模块是否可用
        let hasPermission = true;
        if (typeof window !== 'undefined' && window.permissionManager) {
            const permissionStatus = await window.permissionManager.getGeolocationPermission();
            hasPermission = permissionStatus === 'granted';
        }

        // 模拟GPS定位
        // 实际项目中应使用浏览器的Geolocation API或原生GPS API
        return new Promise((resolve, reject) => {
            if (typeof navigator !== 'undefined' && navigator.geolocation && hasPermission) {
                navigator.geolocation.getCurrentPosition(
                    (position) => {
                        resolve({
                            latitude: position.coords.latitude,
                            longitude: position.coords.longitude,
                            accuracy: position.coords.accuracy,
                            timestamp: position.timestamp,
                            source: this.name
                        });
                    },
                    (error) => {
                        // 模拟GPS定位数据，用于测试
                        this._mockGPSLocation(resolve, reject);
                    },
                    {
                        enableHighAccuracy: true,
                        timeout: 5000,
                        maximumAge: 0
                    }
                );
            } else {
                // 模拟GPS定位数据，用于测试
                this._mockGPSLocation(resolve, reject);
            }
        });
    }

    /**
     * 模拟GPS定位数据
     * @private
     */
    _mockGPSLocation(resolve, reject) {
        setTimeout(() => {
            // 模拟北京市中心附近的GPS坐标，添加一些随机误差
            const baseLat = 39.9042;
            const baseLon = 116.4074;
            const error = 0.001; // 约100米误差

            resolve({
                latitude: baseLat + (Math.random() - 0.5) * error,
                longitude: baseLon + (Math.random() - 0.5) * error,
                accuracy: Math.random() * 10 + 5, // 5-15米精度
                timestamp: Date.now(),
                source: this.name
            });
        }, 200);
    }

    getName() {
        return this.name;
    }

    getPriority() {
        return this.priority;
    }

    isAvailable() {
        // 模拟GPS可用性
        return true;
    }
}

/**
 * Wi-Fi定位源
 */
class WifiLocationSource extends LocationSource {
    constructor() {
        super();
        this.name = 'Wi-Fi';
        this.priority = 2;
    }

    async getLocation() {
        if (!this.isAvailable()) {
            throw new Error('Wi-Fi定位不可用');
        }

        // 模拟Wi-Fi定位
        // 实际项目中应使用Wi-Fi定位API或第三方服务
        return new Promise((resolve) => {
            setTimeout(() => {
                // 模拟北京市中心附近的Wi-Fi坐标，添加一些随机误差
                const baseLat = 39.9042;
                const baseLon = 116.4074;
                const error = 0.003; // 约300米误差

                resolve({
                    latitude: baseLat + (Math.random() - 0.5) * error,
                    longitude: baseLon + (Math.random() - 0.5) * error,
                    accuracy: Math.random() * 50 + 30, // 30-80米精度
                    timestamp: Date.now(),
                    source: this.name
                });
            }, 150);
        });
    }

    getName() {
        return this.name;
    }

    getPriority() {
        return this.priority;
    }

    isAvailable() {
        // 模拟Wi-Fi可用性
        return true;
    }
}

/**
 * 基站定位源
 */
class CellTowerLocationSource extends LocationSource {
    constructor() {
        super();
        this.name = 'CellTower';
        this.priority = 3;
    }

    async getLocation() {
        if (!this.isAvailable()) {
            throw new Error('基站定位不可用');
        }

        // 模拟基站定位
        // 实际项目中应使用基站定位API或第三方服务
        return new Promise((resolve) => {
            setTimeout(() => {
                // 模拟北京市中心附近的基站坐标，添加一些随机误差
                const baseLat = 39.9042;
                const baseLon = 116.4074;
                const error = 0.01; // 约1公里误差

                resolve({
                    latitude: baseLat + (Math.random() - 0.5) * error,
                    longitude: baseLon + (Math.random() - 0.5) * error,
                    accuracy: Math.random() * 200 + 100, // 100-300米精度
                    timestamp: Date.now(),
                    source: this.name
                });
            }, 100);
        });
    }

    getName() {
        return this.name;
    }

    getPriority() {
        return this.priority;
    }

    isAvailable() {
        // 模拟基站可用性
        return true;
    }
}

/**
 * 蓝牙定位源
 */
class BluetoothLocationSource extends LocationSource {
    constructor() {
        super();
        this.name = 'Bluetooth';
        this.priority = 2.5; // 优先级介于Wi-Fi和基站之间
    }

    async getLocation() {
        if (!this.isAvailable()) {
            throw new Error('蓝牙定位不可用');
        }

        // 模拟蓝牙定位
        // 实际项目中应使用蓝牙Beacon或蓝牙三角定位
        return new Promise((resolve) => {
            setTimeout(() => {
                // 模拟北京市中心附近的蓝牙坐标，精度较好
                const baseLat = 39.9042;
                const baseLon = 116.4074;
                const error = 0.002; // 约200米误差

                resolve({
                    latitude: baseLat + (Math.random() - 0.5) * error,
                    longitude: baseLon + (Math.random() - 0.5) * error,
                    accuracy: Math.random() * 50 + 20, // 20-70米精度
                    timestamp: Date.now(),
                    source: this.name
                });
            }, 120);
        });
    }

    getName() {
        return this.name;
    }

    getPriority() {
        return this.priority;
    }

    isAvailable() {
        // 模拟蓝牙可用性
        return true;
    }
}

/**
 * IP定位源（作为最后的备选）
 */
class IPLocationSource extends LocationSource {
    constructor() {
        super();
        this.name = 'IP';
        this.priority = 5;
    }

    async getLocation() {
        if (!this.isAvailable()) {
            throw new Error('IP定位不可用');
        }

        // 模拟IP定位
        // 实际项目中应使用IP定位API或第三方服务
        return new Promise((resolve) => {
            setTimeout(() => {
                // 模拟北京市中心附近的IP坐标，误差较大
                const baseLat = 39.9042;
                const baseLon = 116.4074;
                const error = 0.1; // 约10公里误差

                resolve({
                    latitude: baseLat + (Math.random() - 0.5) * error,
                    longitude: baseLon + (Math.random() - 0.5) * error,
                    accuracy: Math.random() * 5000 + 1000, // 1000-6000米精度
                    timestamp: Date.now(),
                    source: this.name
                });
            }, 50);
        });
    }

    getName() {
        return this.name;
    }

    getPriority() {
        return this.priority;
    }

    isAvailable() {
        // IP定位几乎总是可用的
        return true;
    }
}

/**
 * 定位数据融合算法
 */
class LocationFusionAlgorithm {
    /**
     * 融合多个定位源的数据
     * @param {Array<Object>} locationDataList - 定位数据列表
     * @returns {Object} 融合后的定位数据
     */
    fuse(locationDataList) {
        if (!locationDataList || locationDataList.length === 0) {
            throw new Error('没有可用的定位数据');
        }

        if (locationDataList.length === 1) {
            return locationDataList[0];
        }

        // 检测并过滤异常值
        const filteredDataList = this._detectAndFilterOutliers(locationDataList);

        if (filteredDataList.length === 0) {
            throw new Error('所有定位数据都是异常值');
        }

        if (filteredDataList.length === 1) {
            return filteredDataList[0];
        }

        // 使用加权平均算法融合定位数据
        // 精度越高、时间越新的定位源，权重越大
        let totalWeight = 0;
        let weightedLatitude = 0;
        let weightedLongitude = 0;
        const now = Date.now();

        for (const data of filteredDataList) {
            // 精度权重：精度的倒数（精度单位为米）
            const accuracyWeight = 1 / (data.accuracy || 100);
            
            // 时间权重：时间越新权重越大，衰减因子为10秒
            const timeDiff = now - (data.timestamp || now);
            const timeWeight = Math.exp(-timeDiff / 10000); // 10秒衰减
            
            // 综合权重
            const weight = accuracyWeight * timeWeight;
            
            totalWeight += weight;
            weightedLatitude += data.latitude * weight;
            weightedLongitude += data.longitude * weight;
        }

        const fusedLatitude = weightedLatitude / totalWeight;
        const fusedLongitude = weightedLongitude / totalWeight;

        // 计算融合后的精度估计
        // 使用加权平均的精度
        let weightedAccuracySum = 0;
        for (const data of filteredDataList) {
            const accuracyWeight = 1 / (data.accuracy || 100);
            weightedAccuracySum += accuracyWeight * data.accuracy;
        }
        const fusedAccuracy = weightedAccuracySum / totalWeight * 0.8; // 融合后精度有所提高

        return {
            latitude: fusedLatitude,
            longitude: fusedLongitude,
            accuracy: fusedAccuracy,
            timestamp: Date.now(),
            source: 'Fused',
            sources: filteredDataList.map(data => data.source),
            confidence: this._calculateConfidence(filteredDataList, fusedAccuracy),
            originalCount: locationDataList.length,
            filteredCount: filteredDataList.length
        };
    }

    /**
     * 检测并过滤异常值
     * @param {Array<Object>} locationDataList - 定位数据列表
     * @returns {Array<Object>} 过滤后的定位数据列表
     * @private
     */
    _detectAndFilterOutliers(locationDataList) {
        if (locationDataList.length <= 2) {
            return locationDataList; // 数据量不足，无法检测异常值
        }

        // 计算所有点的中心点
        let centerLat = 0;
        let centerLon = 0;
        for (const data of locationDataList) {
            centerLat += data.latitude;
            centerLon += data.longitude;
        }
        centerLat /= locationDataList.length;
        centerLon /= locationDataList.length;

        // 计算每个点到中心点的距离
        const distances = [];
        for (const data of locationDataList) {
            const distance = this._calculateDistance(
                data.latitude, data.longitude, centerLat, centerLon
            );
            distances.push({ data, distance });
        }

        // 计算平均距离和标准差
        let sumDistance = 0;
        for (const item of distances) {
            sumDistance += item.distance;
        }
        const meanDistance = sumDistance / distances.length;

        let sumSquaredDiff = 0;
        for (const item of distances) {
            sumSquaredDiff += Math.pow(item.distance - meanDistance, 2);
        }
        const stdDev = Math.sqrt(sumSquaredDiff / distances.length);

        // 过滤掉距离中心点超过2倍标准差的点
        const threshold = 2 * stdDev;
        return distances
            .filter(item => item.distance <= threshold)
            .map(item => item.data);
    }

    /**
     * 计算两点之间的距离
     * @param {number} lat1 - 第一个点的纬度
     * @param {number} lon1 - 第一个点的经度
     * @param {number} lat2 - 第二个点的纬度
     * @param {number} lon2 - 第二个点的经度
     * @returns {number} 距离（米）
     * @private
     */
    _calculateDistance(lat1, lon1, lat2, lon2) {
        const R = 6371e3; // 地球半径（单位：米）
        const φ1 = (lat1 * Math.PI) / 180;
        const φ2 = (lat2 * Math.PI) / 180;
        const Δφ = ((lat2 - lat1) * Math.PI) / 180;
        const Δλ = ((lon2 - lon1) * Math.PI) / 180;

        const a = Math.sin(Δφ / 2) * Math.sin(Δφ / 2) +
                  Math.cos(φ1) * Math.cos(φ2) *
                  Math.sin(Δλ / 2) * Math.sin(Δλ / 2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

        return R * c;
    }

    /**
     * 计算融合结果的置信度
     * @param {Array<Object>} locationDataList - 定位数据列表
     * @param {number} fusedAccuracy - 融合后的精度
     * @returns {number} 置信度（0-1）
     * @private
     */
    _calculateConfidence(locationDataList, fusedAccuracy) {
        // 基于数据源数量、平均精度和融合精度计算置信度
        const sourceCount = locationDataList.length;
        const avgAccuracy = locationDataList.reduce((sum, data) => sum + data.accuracy, 0) / sourceCount;
        
        // 数据源数量权重（0-0.4）
        const sourceWeight = Math.min(sourceCount / 5, 1) * 0.4;
        
        // 精度改善权重（0-0.6）
        const accuracyImprovement = avgAccuracy > 0 ? (avgAccuracy - fusedAccuracy) / avgAccuracy : 0;
        const accuracyWeight = Math.min(accuracyImprovement, 1) * 0.6;
        
        return sourceWeight + accuracyWeight;
    }

    /**
     * 根据环境选择最优定位方式
     * @param {Array<LocationSource>} availableSources - 可用的定位源列表
     * @param {Object} environmentData - 环境数据
     * @returns {Array<LocationSource>} 排序后的定位源列表，优先级从高到低
     */
    selectOptimalSources(availableSources, environmentData = {}) {
        // 基础排序：按优先级排序
        const sortedSources = [...availableSources].sort((a, b) => a.getPriority() - b.getPriority());

        // 根据环境数据调整优先级
        if (environmentData.indoor) {
            // 室内环境：Wi-Fi和蓝牙优先级提高
            sortedSources.sort((a, b) => {
                if (a.getName() === 'Wi-Fi') return -2;
                if (b.getName() === 'Wi-Fi') return 2;
                if (a.getName() === 'Bluetooth') return -1;
                if (b.getName() === 'Bluetooth') return 1;
                return a.getPriority() - b.getPriority();
            });
        } else if (environmentData.gpsSignalStrength && environmentData.gpsSignalStrength > 3) {
            // GPS信号强：保持GPS最高优先级
            // 无需调整
        } else if (environmentData.networkType === '4G' || environmentData.networkType === '5G') {
            // 移动网络信号好：基站定位优先级提高
            sortedSources.sort((a, b) => {
                if (a.getName() === 'CellTower') return -2;
                if (b.getName() === 'CellTower') return 2;
                return a.getPriority() - b.getPriority();
            });
        } else if (environmentData.networkType === 'Wi-Fi') {
            // Wi-Fi网络：Wi-Fi和蓝牙优先级提高
            sortedSources.sort((a, b) => {
                if (a.getName() === 'Wi-Fi') return -2;
                if (b.getName() === 'Wi-Fi') return 2;
                if (a.getName() === 'Bluetooth') return -1;
                if (b.getName() === 'Bluetooth') return 1;
                return a.getPriority() - b.getPriority();
            });
        }

        return sortedSources;
    }
}

/**
 * 环境检测器
 */
class EnvironmentDetector {
    /**
     * 检测当前环境
     * @returns {Promise<Object>} 环境数据对象
     */
    async detect() {
        return {
            indoor: this._detectIndoor(),
            gpsSignalStrength: this._detectGPSSignalStrength(),
            networkType: this._detectNetworkType(),
            batteryLevel: this._detectBatteryLevel(),
            timestamp: Date.now()
        };
    }

    /**
     * 检测是否在室内
     * @private
     */
    _detectIndoor() {
        // 模拟室内检测
        // 实际项目中可通过加速度传感器、光线传感器等数据判断
        return Math.random() > 0.5;
    }

    /**
     * 检测GPS信号强度
     * @private
     */
    _detectGPSSignalStrength() {
        // 模拟GPS信号强度检测（0-5，5最强）
        return Math.floor(Math.random() * 6);
    }

    /**
     * 检测网络类型
     * @private
     */
    _detectNetworkType() {
        // 模拟网络类型检测
        const networkTypes = ['2G', '3G', '4G', '5G', 'Wi-Fi'];
        return networkTypes[Math.floor(Math.random() * networkTypes.length)];
    }

    /**
     * 检测电池电量
     * @private
     */
    _detectBatteryLevel() {
        // 模拟电池电量检测
        return Math.random() * 100;
    }
}

/**
 * 多源定位融合服务
 * 
 * 核心功能：
 * - 集成多种定位源（GPS、Wi-Fi、蓝牙、基站、IP）
 * - 智能定位数据融合算法
 * - 动态优先级调整
 * - 定位源健康状态监控
 * - 错误恢复机制
 * - 精度评估
 * - 缓存管理
 * 
 * 使用示例：
 * ```javascript
 * const locationService = new MultiSourceLocationService();
 * 
 * // 基本定位
 * const location = await locationService.getFusedLocation();
 * 
 * // 带精度要求的定位
 * const highAccuracyLocation = await locationService.getFusedLocation({
 *   minAccuracy: 50, // 要求精度在50米以内
 *   enableErrorRecovery: true // 启用错误恢复
 * });
 * 
 * // 获取性能统计
 * const stats = locationService.getPerformanceStats();
 * ```
 */
class MultiSourceLocationService {
    constructor() {
        // 初始化定位源
        this.locationSources = [
            new GPSLocationSource(),
            new WifiLocationSource(),
            new BluetoothLocationSource(),
            new CellTowerLocationSource(),
            new IPLocationSource()
        ];

        // 初始化融合算法
        this.fusionAlgorithm = new LocationFusionAlgorithm();

        // 初始化环境检测器
        this.environmentDetector = new EnvironmentDetector();

        // 缓存
        this.locationCache = null;
        this.cacheExpiryTime = 5000; // 缓存有效期5秒

        // 性能统计
        this.performanceStats = {
            totalRequests: 0,
            successfulRequests: 0,
            averageResponseTime: 0,
            lastResponseTime: 0
        };

        // 定位源健康状态
        this.sourceHealthStatus = new Map();
        
        // 定位源历史记录
        this.sourceHistory = new Map();
        this.maxHistorySize = 10; // 每个定位源最多保存10条历史记录
        
        // 动态优先级调整配置
        this.dynamicPriorityConfig = {
            enabled: true,
            adjustmentInterval: 30000, // 30秒调整一次
            lastAdjustmentTime: 0
        };
    }

    /**
     * 获取融合后的定位数据
     * 
     * @param {Object} options - 选项
     * @param {boolean} options.forceRefresh - 是否强制刷新（不使用缓存）
     * @param {number} options.timeout - 超时时间（毫秒）
     * @param {number} options.minAccuracy - 最小精度要求（米）
     * @param {boolean} options.enableErrorRecovery - 是否启用错误恢复
     * @returns {Promise<Object>} 融合后的定位数据
     * 
     * 返回数据结构：
     * {
     *   latitude: 纬度,
     *   longitude: 经度,
     *   accuracy: 精度（米）,
     *   timestamp: 时间戳,
     *   source: 'Fused',
     *   sources: [定位源名称数组],
     *   confidence: 置信度（0-1）,
     *   accuracyAssessment: {
     *     accuracy: 精度,
     *     accuracyLevel: 精度等级（excellent, good, fair, poor, very_poor）,
     *     confidence: 置信度,
     *     reliability: 可靠性（high, medium, low）,
     *     meetsAccuracyRequirement: 是否满足精度要求,
     *     recommendation: 建议操作（use, retry, retry_with_more_sources）
     *   },
     *   fromCache: 是否来自缓存,
     *   usedFallback: 是否使用了备用定位源,
     *   errorRecovered: 是否从错误中恢复
     * }
     */
    async getFusedLocation(options = {}) {
        const startTime = Date.now();
        this.performanceStats.totalRequests++;

        try {
            // 检查缓存
            if (!options.forceRefresh && this._isCacheValid()) {
                const cachedLocation = this.locationCache;
                
                // 检查缓存数据是否满足精度要求
                if (options.minAccuracy && cachedLocation.accuracy > options.minAccuracy) {
                    console.log('缓存数据精度不满足要求，需要刷新');
                } else {
                    this.performanceStats.successfulRequests++;
                    this.performanceStats.lastResponseTime = Date.now() - startTime;
                    this._updateAverageResponseTime(this.performanceStats.lastResponseTime);
                    return {
                        ...cachedLocation,
                        fromCache: true
                    };
                }
            }

            // 检查是否需要调整动态优先级
            this._checkAndAdjustDynamicPriorities();

            // 检测环境
            const environmentData = await this.environmentDetector.detect();

            // 获取可用的定位源
            const availableSources = this.locationSources.filter(source => source.isAvailable());

            if (availableSources.length === 0) {
                // 尝试错误恢复
                if (options.enableErrorRecovery) {
                    return this._recoverFromNoSourcesError();
                }
                throw new Error('没有可用的定位源');
            }

            // 选择最优定位源
            const optimalSources = this.fusionAlgorithm.selectOptimalSources(availableSources, environmentData);

            // 限制同时使用的定位源数量，平衡精度和性能
            const maxSources = 3;
            const sourcesToUse = optimalSources.slice(0, maxSources);

            // 并行获取多个定位源的数据
            const timeoutPromise = new Promise((_, reject) => {
                setTimeout(() => reject(new Error('定位超时')), options.timeout || 3000);
            });

            const locationDataPromises = sourcesToUse.map(source => {
                return this._getSourceLocationWithHealthMonitoring(source).catch(error => {
                    console.warn(`获取${source.getName()}定位数据失败:`, error);
                    this._updateSourceHealthStatus(source.getName(), false);
                    return null;
                });
            });

            let locationDataResults;
            try {
                locationDataResults = await Promise.race([
                    Promise.all(locationDataPromises),
                    timeoutPromise
                ]);
            } catch (timeoutError) {
                console.warn('定位超时，尝试使用部分成功的定位数据');
                // 尝试获取已完成的定位数据
                const settledResults = await Promise.allSettled(locationDataPromises);
                locationDataResults = settledResults.map(result => 
                    result.status === 'fulfilled' ? result.value : null
                );
            }

            // 过滤掉失败的定位数据
            const validLocationData = locationDataResults.filter(data => data !== null);

            if (validLocationData.length === 0) {
                // 尝试使用备用定位源
                const fallbackSources = this._getFallbackSources(optimalSources, availableSources);
                if (fallbackSources.length > 0) {
                    const fallbackDataPromises = fallbackSources.slice(0, 2).map(source => {
                        return this._getSourceLocationWithHealthMonitoring(source).catch(error => {
                            console.warn(`获取备用${source.getName()}定位数据失败:`, error);
                            this._updateSourceHealthStatus(source.getName(), false);
                            return null;
                        });
                    });

                    const fallbackResults = await Promise.all(fallbackDataPromises);
                    const validFallbackData = fallbackResults.filter(data => data !== null);

                    if (validFallbackData.length > 0) {
                        const fusedLocation = this.fusionAlgorithm.fuse(validFallbackData);
                        
                        // 评估精度是否满足要求
                        const accuracyAssessment = this._assessLocationAccuracy(fusedLocation, options.minAccuracy);
                        const locationWithAssessment = {
                            ...fusedLocation,
                            usedFallback: true,
                            accuracyAssessment: accuracyAssessment
                        };
                        
                        this._updateCacheAndStats(locationWithAssessment, startTime);
                        return locationWithAssessment;
                    }
                }
                
                // 尝试错误恢复
                if (options.enableErrorRecovery) {
                    return this._recoverFromNoDataError();
                }
                
                throw new Error('无法获取任何定位数据');
            }

            // 融合定位数据
            const fusedLocation = this.fusionAlgorithm.fuse(validLocationData);
            
            // 评估精度是否满足要求
            const accuracyAssessment = this._assessLocationAccuracy(fusedLocation, options.minAccuracy);
            const locationWithAssessment = {
                ...fusedLocation,
                accuracyAssessment: accuracyAssessment
            };

            // 更新缓存和统计
            this._updateCacheAndStats(locationWithAssessment, startTime);

            return locationWithAssessment;
        } catch (error) {
            console.error('获取融合定位数据失败:', error);
            
            // 尝试错误恢复
            if (options.enableErrorRecovery) {
                return this._recoverFromGeneralError(error);
            }
            
            throw error;
        }
    }

    /**
     * 评估定位精度
     * @param {Object} locationData - 定位数据
     * @param {number} minAccuracy - 最小精度要求（米）
     * @returns {Object} 精度评估结果
     * @private
     */
    _assessLocationAccuracy(locationData, minAccuracy = null) {
        const accuracy = locationData.accuracy;
        const confidence = locationData.confidence || 0;
        
        // 精度等级评估
        let accuracyLevel;
        if (accuracy < 10) {
            accuracyLevel = 'excellent';
        } else if (accuracy < 30) {
            accuracyLevel = 'good';
        } else if (accuracy < 100) {
            accuracyLevel = 'fair';
        } else if (accuracy < 300) {
            accuracyLevel = 'poor';
        } else {
            accuracyLevel = 'very_poor';
        }
        
        // 精度是否满足要求
        const meetsAccuracyRequirement = !minAccuracy || accuracy <= minAccuracy;
        
        // 可靠性评估
        let reliability;
        if (confidence > 0.8) {
            reliability = 'high';
        } else if (confidence > 0.5) {
            reliability = 'medium';
        } else {
            reliability = 'low';
        }
        
        // 建议操作
        let recommendation = 'use';
        if (accuracyLevel === 'very_poor' || reliability === 'low') {
            recommendation = 'retry';
        } else if (accuracyLevel === 'poor' && !meetsAccuracyRequirement) {
            recommendation = 'retry_with_more_sources';
        }
        
        return {
            accuracy: accuracy,
            accuracyLevel: accuracyLevel,
            confidence: confidence,
            reliability: reliability,
            meetsAccuracyRequirement: meetsAccuracyRequirement,
            recommendation: recommendation,
            timestamp: Date.now()
        };
    }

    /**
     * 从无定位源错误中恢复
     * @returns {Promise<Object>} 恢复后的定位数据
     * @private
     */
    async _recoverFromNoSourcesError() {
        console.log('尝试从无定位源错误中恢复');
        
        // 1. 尝试使用缓存数据
        if (this.locationCache) {
            console.log('使用缓存数据进行恢复');
            return {
                ...this.locationCache,
                fromCache: true,
                errorRecovered: true,
                recoveryReason: 'no_sources'
            };
        }
        
        // 2. 尝试重新检测定位源
        console.log('重新检测定位源');
        await new Promise(resolve => setTimeout(resolve, 1000)); // 等待1秒后重试
        
        const availableSources = this.locationSources.filter(source => source.isAvailable());
        if (availableSources.length > 0) {
            console.log('重新检测到定位源:', availableSources.map(s => s.getName()));
            return this.getFusedLocation({ forceRefresh: true });
        }
        
        // 3. 抛出最终错误
        throw new Error('无法从无定位源错误中恢复');
    }

    /**
     * 从无数据错误中恢复
     * @returns {Promise<Object>} 恢复后的定位数据
     * @private
     */
    async _recoverFromNoDataError() {
        console.log('尝试从无数据错误中恢复');
        
        // 1. 尝试使用缓存数据
        if (this.locationCache) {
            console.log('使用缓存数据进行恢复');
            return {
                ...this.locationCache,
                fromCache: true,
                errorRecovered: true,
                recoveryReason: 'no_data'
            };
        }
        
        // 2. 尝试使用所有可用定位源
        console.log('尝试使用所有可用定位源');
        const availableSources = this.locationSources.filter(source => source.isAvailable());
        
        if (availableSources.length > 0) {
            const locationDataPromises = availableSources.map(source => {
                return this._getSourceLocationWithHealthMonitoring(source).catch(error => {
                    console.warn(`恢复时获取${source.getName()}定位数据失败:`, error);
                    return null;
                });
            });
            
            const locationDataResults = await Promise.all(locationDataPromises);
            const validLocationData = locationDataResults.filter(data => data !== null);
            
            if (validLocationData.length > 0) {
                const fusedLocation = this.fusionAlgorithm.fuse(validLocationData);
                const accuracyAssessment = this._assessLocationAccuracy(fusedLocation);
                
                return {
                    ...fusedLocation,
                    accuracyAssessment: accuracyAssessment,
                    errorRecovered: true,
                    recoveryReason: 'no_data'
                };
            }
        }
        
        // 3. 抛出最终错误
        throw new Error('无法从无数据错误中恢复');
    }

    /**
     * 从一般错误中恢复
     * @param {Error} error - 原始错误
     * @returns {Promise<Object>} 恢复后的定位数据
     * @private
     */
    async _recoverFromGeneralError(error) {
        console.log('尝试从一般错误中恢复:', error.message);
        
        // 1. 尝试使用缓存数据
        if (this.locationCache) {
            console.log('使用缓存数据进行恢复');
            return {
                ...this.locationCache,
                fromCache: true,
                errorRecovered: true,
                recoveryReason: 'general_error',
                originalError: error.message
            };
        }
        
        // 2. 尝试使用IP定位（最基本的定位方式）
        console.log('尝试使用IP定位进行恢复');
        try {
            const ipSource = this.locationSources.find(s => s.getName() === 'IP');
            if (ipSource && ipSource.isAvailable()) {
                const ipLocation = await ipSource.getLocation();
                const accuracyAssessment = this._assessLocationAccuracy(ipLocation);
                
                return {
                    ...ipLocation,
                    accuracyAssessment: accuracyAssessment,
                    errorRecovered: true,
                    recoveryReason: 'general_error',
                    originalError: error.message
                };
            }
        } catch (ipError) {
            console.warn('IP定位恢复失败:', ipError.message);
        }
        
        // 3. 抛出最终错误
        throw new Error(`无法从错误中恢复: ${error.message}`);
    }

    /**
     * 获取定位源数据并监控健康状态
     * @param {LocationSource} source - 定位源
     * @returns {Promise<Object>} 定位数据
     * @private
     */
    async _getSourceLocationWithHealthMonitoring(source) {
        const sourceName = source.getName();
        const startTime = Date.now();

        try {
            const locationData = await source.getLocation();
            const responseTime = Date.now() - startTime;

            // 更新健康状态
            this._updateSourceHealthStatus(sourceName, true, responseTime);

            // 记录历史数据
            this._recordSourceHistory(sourceName, locationData, responseTime);

            return locationData;
        } catch (error) {
            this._updateSourceHealthStatus(sourceName, false);
            throw error;
        }
    }

    /**
     * 更新定位源健康状态
     * @param {string} sourceName - 定位源名称
     * @param {boolean} success - 是否成功
     * @param {number} responseTime - 响应时间
     * @private
     */
    _updateSourceHealthStatus(sourceName, success, responseTime = 0) {
        const now = Date.now();
        const currentStatus = this.sourceHealthStatus.get(sourceName) || {
            successCount: 0,
            failureCount: 0,
            totalRequests: 0,
            successRate: 1.0,
            averageResponseTime: 0,
            lastUpdateTime: now,
            consecutiveFailures: 0
        };

        if (success) {
            currentStatus.successCount++;
            currentStatus.consecutiveFailures = 0;
            if (responseTime > 0) {
                // 平滑更新平均响应时间
                const alpha = 0.1;
                currentStatus.averageResponseTime = 
                    currentStatus.averageResponseTime * (1 - alpha) + responseTime * alpha;
            }
        } else {
            currentStatus.failureCount++;
            currentStatus.consecutiveFailures++;
        }

        currentStatus.totalRequests++;
        currentStatus.successRate = currentStatus.successCount / currentStatus.totalRequests;
        currentStatus.lastUpdateTime = now;

        this.sourceHealthStatus.set(sourceName, currentStatus);
    }

    /**
     * 记录定位源历史数据
     * @param {string} sourceName - 定位源名称
     * @param {Object} locationData - 定位数据
     * @param {number} responseTime - 响应时间
     * @private
     */
    _recordSourceHistory(sourceName, locationData, responseTime) {
        if (!this.sourceHistory.has(sourceName)) {
            this.sourceHistory.set(sourceName, []);
        }

        const history = this.sourceHistory.get(sourceName);
        history.push({
            timestamp: Date.now(),
            locationData: locationData,
            responseTime: responseTime,
            accuracy: locationData.accuracy
        });

        // 限制历史记录大小
        if (history.length > this.maxHistorySize) {
            history.shift();
        }

        this.sourceHistory.set(sourceName, history);
    }

    /**
     * 获取备用定位源
     * @param {Array<LocationSource>} usedSources - 已使用的定位源
     * @param {Array<LocationSource>} availableSources - 所有可用的定位源
     * @returns {Array<LocationSource>} 备用定位源列表
     * @private
     */
    _getFallbackSources(usedSources, availableSources) {
        const usedSourceNames = new Set(usedSources.map(source => source.getName()));
        return availableSources
            .filter(source => !usedSourceNames.has(source.getName()))
            .sort((a, b) => {
                // 优先选择健康状态好的定位源
                const healthA = this.sourceHealthStatus.get(a.getName()) || { successRate: 0 };
                const healthB = this.sourceHealthStatus.get(b.getName()) || { successRate: 0 };
                return healthB.successRate - healthA.successRate;
            });
    }

    /**
     * 检查并调整动态优先级
     * @private
     */
    _checkAndAdjustDynamicPriorities() {
        if (!this.dynamicPriorityConfig.enabled) {
            return;
        }

        const now = Date.now();
        if (now - this.dynamicPriorityConfig.lastAdjustmentTime < this.dynamicPriorityConfig.adjustmentInterval) {
            return;
        }

        // 调整定位源优先级
        for (const source of this.locationSources) {
            const sourceName = source.getName();
            const healthStatus = this.sourceHealthStatus.get(sourceName);

            if (healthStatus) {
                // 基于健康状态调整优先级
                const basePriority = this._getBasePriority(sourceName);
                let dynamicAdjustment = 0;

                // 连续失败会降低优先级
                if (healthStatus.consecutiveFailures > 2) {
                    dynamicAdjustment += healthStatus.consecutiveFailures * 0.5;
                }

                // 响应时间过长会降低优先级
                if (healthStatus.averageResponseTime > 1000) {
                    dynamicAdjustment += Math.min((healthStatus.averageResponseTime - 1000) / 1000, 2);
                }

                // 设置新的优先级
                source.priority = basePriority + dynamicAdjustment;
            }
        }

        this.dynamicPriorityConfig.lastAdjustmentTime = now;
    }

    /**
     * 获取定位源的基础优先级
     * @param {string} sourceName - 定位源名称
     * @returns {number} 基础优先级
     * @private
     */
    _getBasePriority(sourceName) {
        const basePriorities = {
            'GPS': 1,
            'Wi-Fi': 2,
            'Bluetooth': 2.5,
            'CellTower': 3,
            'IP': 5
        };
        return basePriorities[sourceName] || 10;
    }

    /**
     * 更新缓存和统计信息
     * @param {Object} locationData - 定位数据
     * @param {number} startTime - 开始时间
     * @private
     */
    _updateCacheAndStats(locationData, startTime) {
        // 更新缓存
        this.locationCache = locationData;
        this.locationCache.cachedAt = Date.now();

        // 更新性能统计
        this.performanceStats.successfulRequests++;
        this.performanceStats.lastResponseTime = Date.now() - startTime;
        this._updateAverageResponseTime(this.performanceStats.lastResponseTime);
    }

    /**
     * 检查缓存是否有效
     * @private
     */
    _isCacheValid() {
        if (!this.locationCache) {
            return false;
        }

        const now = Date.now();
        const cacheAge = now - (this.locationCache.cachedAt || 0);
        return cacheAge < this.cacheExpiryTime;
    }

    /**
     * 更新平均响应时间
     * @param {number} responseTime - 当前响应时间
     * @private
     */
    _updateAverageResponseTime(responseTime) {
        const alpha = 0.1; // 平滑因子
        this.performanceStats.averageResponseTime = 
            this.performanceStats.averageResponseTime * (1 - alpha) + responseTime * alpha;
    }

    /**
     * 获取性能统计数据
     * @returns {Object} 性能统计数据
     */
    getPerformanceStats() {
        return { ...this.performanceStats };
    }

    /**
     * 清空缓存
     */
    clearCache() {
        this.locationCache = null;
    }

    /**
     * 添加自定义定位源
     * @param {LocationSource} locationSource - 自定义定位源
     */
    addLocationSource(locationSource) {
        if (locationSource instanceof LocationSource) {
            this.locationSources.push(locationSource);
        } else {
            throw new Error('定位源必须是LocationSource的实例');
        }
    }
}

// 导出模块
const multiSourceLocationService = {
    LocationSource,
    GPSLocationSource,
    WifiLocationSource,
    BluetoothLocationSource,
    CellTowerLocationSource,
    IPLocationSource,
    LocationFusionAlgorithm,
    EnvironmentDetector,
    MultiSourceLocationService
};

// 全局变量，方便其他脚本使用
if (typeof window !== 'undefined') {
    window.multiSourceLocationService = multiSourceLocationService;
}

// 导出默认服务实例
const locationService = new MultiSourceLocationService();
if (typeof window !== 'undefined') {
    window.locationService = locationService;
}

// 模块导出
if (typeof module !== 'undefined' && module.exports) {
    module.exports = multiSourceLocationService;
    module.exports.locationService = locationService;
}

// 尝试加载离线定位增强器
if (typeof window !== 'undefined') {
    // 延迟加载离线定位模块，避免循环依赖
    setTimeout(async () => {
        try {
            // 尝试动态导入离线定位模块
            if (window.offlineLocation) {
                const { OfflineLocationEnhancer } = window.offlineLocation;
                const enhancer = new OfflineLocationEnhancer();
                enhancer.initialize(locationService);
                
                console.log('离线定位增强器初始化成功');
            }
        } catch (error) {
            console.warn('加载离线定位增强器失败:', error);
        }
    }, 1000);
    
    // 延迟加载多级降级策略模块
    setTimeout(async () => {
        try {
            // 尝试动态导入多级降级策略模块
            if (window.networkFallbackStrategy) {
                const { FallbackStrategyManager } = window.networkFallbackStrategy;
                const fallbackManager = new FallbackStrategyManager();
                fallbackManager.initialize(locationService);
                
                // 增强定位服务，添加降级策略支持
                const originalGetFusedLocation = locationService.getFusedLocation;
                locationService.getFusedLocation = async (options = {}) => {
                    // 检查是否有离线定位增强器，优先使用离线模式
                    if (window.offlineLocation && window.offlineLocation.OfflineLocationEnhancer) {
                        const enhancer = new window.offlineLocation.OfflineLocationEnhancer();
                        if (enhancer.isOfflineMode) {
                            return enhancer.enhanceLocationRequest(options);
                        }
                    }
                    
                    // 使用多级降级策略
                    try {
                        return await fallbackManager.executeLocation(options);
                    } catch (error) {
                        console.warn('降级策略执行失败，使用原始定位方法:', error.message);
                        // 降级失败时使用原始定位方法
                        const locationData = await originalGetFusedLocation(options);
                        
                        // 缓存定位数据，为离线模式做准备
                        if (window.offlineLocation && window.offlineLocation.OfflineLocationSource) {
                            const offlineSource = new window.offlineLocation.OfflineLocationSource();
                            offlineSource.cacheLocation(locationData);
                        }
                        
                        return locationData;
                    }
                };
                
                // 添加降级策略管理器到定位服务
                locationService.fallbackManager = fallbackManager;
                
                console.log('多级降级策略管理器初始化成功');
            }
        } catch (error) {
            console.warn('加载多级降级策略管理器失败:', error);
        }
    }, 1500);
    
    // 延迟加载实时更新模块
    setTimeout(async () => {
        try {
            // 尝试动态导入实时更新模块
            if (window.RealTimeUpdateManager) {
                // 创建实时更新管理器实例
                const realTimeUpdateManager = new window.RealTimeUpdateManager({
                    locationProvider: () => locationService.getFusedLocation({ forceRefresh: true }),
                    updateCallback: (location) => {
                        console.log('实时位置更新:', location);
                        // 更新缓存
                        locationService.locationCache = location;
                        locationService.locationCache.cachedAt = Date.now();
                        
                        // 触发位置更新事件
                        if (typeof window !== 'undefined') {
                            const event = new CustomEvent('locationUpdated', { detail: location });
                            window.dispatchEvent(event);
                        }
                    }
                });
                
                // 为定位服务添加实时更新相关方法
                locationService.realTimeUpdateManager = realTimeUpdateManager;
                
                locationService.startRealTimeUpdates = () => {
                    return realTimeUpdateManager.start();
                };
                
                locationService.stopRealTimeUpdates = () => {
                    return realTimeUpdateManager.stop();
                };
                
                locationService.updateLocationManually = () => {
                    return realTimeUpdateManager.updateLocation();
                };
                
                locationService.getRealTimeUpdateState = () => {
                    return realTimeUpdateManager.getCurrentState();
                };
                
                locationService.getRealTimeUpdatePerformanceStats = () => {
                    return realTimeUpdateManager.getPerformanceStats();
                };
                
                console.log('实时更新机制初始化成功');
            }
        } catch (error) {
            console.warn('加载实时更新模块失败:', error);
        }
    }, 2000);
}
