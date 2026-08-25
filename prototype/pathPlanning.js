/**
 * 路径规划服务模块
 * 集成高德地图路径规划API，实现用户位置到资源/需求位置的路径计算
 * 支持步行、驾车、公交等多种交通方式
 */

class PathPlanningService {
    /**
     * 构造函数
     * @param {string} key - 高德地图API密钥
     */
    constructor(key) {
        this.key = key;
        this.baseUrl = 'https://restapi.amap.com/v3/direction';
        this.memoryCache = new Map();
        this.memoryCacheExpiry = 3600000; // 内存缓存过期时间（1小时）
        this.localStorageKey = 'path_planning_cache';
        this.maxCacheSize = 100; // 最大缓存条目数
        this.initCache();
    }

    /**
     * 初始化缓存
     */
    initCache() {
        // 尝试从本地存储加载缓存
        try {
            if (typeof localStorage !== 'undefined') {
                const storedCache = localStorage.getItem(this.localStorageKey);
                if (storedCache) {
                    const cacheData = JSON.parse(storedCache);
                    // 只加载未过期的缓存
                    const now = Date.now();
                    Object.entries(cacheData).forEach(([key, value]) => {
                        if (now - value.timestamp < this.memoryCacheExpiry) {
                            this.memoryCache.set(key, value);
                        }
                    });
                    console.log('从本地存储加载缓存，当前缓存大小:', this.memoryCache.size);
                }
            }
        } catch (error) {
            console.error('加载本地缓存失败:', error);
        }
    }

    /**
     * 计算路径
     * @param {Object} origin - 起点坐标 {lng, lat}
     * @param {Object} destination - 终点坐标 {lng, lat}
     * @param {string} mode - 交通方式：walking, driving, transit
     * @param {Object} options - 可选参数
     * @param {boolean} enableFallback - 是否启用降级方案
     * @returns {Promise<Object>} 路径规划结果
     */
    async calculatePath(origin, destination, mode = 'walking', options = {}, enableFallback = true) {
        // 生成缓存键（优化：使用固定精度的坐标，减少缓存键的数量）
        const originKey = `${parseFloat(origin.lng).toFixed(4)},${parseFloat(origin.lat).toFixed(4)}`;
        const destKey = `${parseFloat(destination.lng).toFixed(4)},${parseFloat(destination.lat).toFixed(4)}`;
        const optionsKey = this.generateOptionsKey(options);
        const cacheKey = `${originKey}_${destKey}_${mode}_${optionsKey}`;
        
        // 检查缓存
        const cachedResult = this.getFromCache(cacheKey);
        if (cachedResult) {
            console.log('使用缓存的路径规划结果');
            return cachedResult;
        }

        try {
            // 构建请求URL
            const url = this.buildUrl(origin, destination, mode, options);
            console.log('路径规划请求URL:', url);

            // 发送请求
            const startTime = Date.now();
            const response = await fetch(url);
            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }

            const data = await response.json();
            const endTime = Date.now();
            console.log('路径规划API响应时间:', endTime - startTime, 'ms');
            console.log('路径规划API响应:', data);

            // 处理响应数据
            if (data.status === '1') {
                const result = this.processResponse(data, mode);
                
                // 存入缓存
                this.saveToCache(cacheKey, result);
                
                return result;
            } else {
                console.error(`路径规划API错误: ${data.info}，错误码: ${data.infocode}`);
                // 特别处理USERKEY_PLAT_NOMATCH错误
                if (data.info === 'USERKEY_PLAT_NOMATCH') {
                    console.warn('API密钥与当前平台不匹配，这通常发生在本地开发环境中');
                    console.warn('建议：1. 检查API密钥配置 2. 在高德地图开放平台配置正确的安全域名 3. 使用降级方案');
                }
                throw new Error(`API error: ${data.info}`);
            }
        } catch (error) {
            console.error('路径规划计算失败:', error);
            
            // 启用降级方案
            if (enableFallback) {
                console.log('启用路径计算降级方案');
                const fallbackResult = this.calculateFallbackPath(origin, destination, mode);
                
                // 存入缓存（降级结果）
                const fallbackCacheKey = `${originKey}_${destKey}_${mode}_fallback`;
                this.saveToCache(fallbackCacheKey, fallbackResult);
                
                return fallbackResult;
            }
            
            throw error;
        }
    }

    /**
     * 计算降级路径（基于直线距离）
     * @param {Object} origin - 起点坐标 {lng, lat}
     * @param {Object} destination - 终点坐标 {lng, lat}
     * @param {string} mode - 交通方式
     * @returns {Object} 降级路径结果
     */
    calculateFallbackPath(origin, destination, mode = 'walking') {
        // 计算直线距离
        const distance = calculateStraightDistance(origin, destination);
        
        // 基于交通方式估算时间
        const estimatedTime = this.estimateTime(distance, mode);
        
        // 生成降级路径结果
        const result = {
            origin: `${origin.lng},${origin.lat}`,
            destination: `${destination.lng},${destination.lat}`,
            mode: mode,
            paths: [{
                distance: Math.round(distance),
                duration: Math.round(estimatedTime),
                isFallback: true,
                // 生成简单的路径步骤
                steps: this.generateFallbackSteps(origin, destination, mode, distance, estimatedTime)
            }],
            timestamp: Date.now(),
            stats: {
                pathCount: 1,
                totalDistance: Math.round(distance),
                totalDuration: Math.round(estimatedTime),
                isFallback: true
            },
            fallback: {
                reason: '路径规划API调用失败，使用直线距离估算',
                distanceAccuracy: 'approximate',
                timeAccuracy: 'approximate',
                mode: mode
            }
        };
        
        console.log('生成降级路径结果:', result);
        return result;
    }

    /**
     * 估算时间（基于距离和交通方式）
     * @param {number} distance - 距离（米）
     * @param {string} mode - 交通方式
     * @returns {number} 估算时间（秒）
     */
    estimateTime(distance, mode) {
        // 不同交通方式的平均速度（米/秒）
        const averageSpeeds = {
            walking: 1.4,     // 步行：约5公里/小时
            driving: 13.89,   // 驾车：约50公里/小时
            transit: 6.94,    // 公交：约25公里/小时
            cycling: 4.17     // 骑行：约15公里/小时
        };
        
        const speed = averageSpeeds[mode] || averageSpeeds.walking;
        return distance / speed;
    }

    /**
     * 生成降级路径步骤
     * @param {Object} origin - 起点坐标
     * @param {Object} destination - 终点坐标
     * @param {string} mode - 交通方式
     * @param {number} distance - 距离
     * @param {number} duration - 时间
     * @returns {Array} 路径步骤
     */
    generateFallbackSteps(origin, destination, mode, distance, duration) {
        const steps = [];
        
        // 生成起点步骤
        steps.push({
            instruction: `从起点出发，向${this.getDirection(origin, destination)}方向前进`,
            distance: 0,
            duration: 0,
            action: 'start',
            road: '',
            polyline: `${origin.lng},${origin.lat};${origin.lng},${origin.lat}`
        });
        
        // 生成中间步骤
        steps.push({
            instruction: `沿直线行驶${Math.round(distance)}米`,
            distance: Math.round(distance),
            duration: Math.round(duration),
            action: 'go_straight',
            road: '',
            polyline: `${origin.lng},${origin.lat};${destination.lng},${destination.lat}`
        });
        
        // 生成终点步骤
        steps.push({
            instruction: '到达目的地',
            distance: 0,
            duration: 0,
            action: 'end',
            road: '',
            polyline: `${destination.lng},${destination.lat};${destination.lng},${destination.lat}`
        });
        
        return steps;
    }

    /**
     * 获取方向
     * @param {Object} origin - 起点坐标
     * @param {Object} destination - 终点坐标
     * @returns {string} 方向
     */
    getDirection(origin, destination) {
        const dx = destination.lng - origin.lng;
        const dy = destination.lat - origin.lat;
        const angle = Math.atan2(dy, dx) * 180 / Math.PI;
        
        if (angle >= -22.5 && angle < 22.5) return '东';
        if (angle >= 22.5 && angle < 67.5) return '东北';
        if (angle >= 67.5 && angle < 112.5) return '北';
        if (angle >= 112.5 && angle < 157.5) return '西北';
        if (angle >= 157.5 || angle < -157.5) return '西';
        if (angle >= -157.5 && angle < -112.5) return '西南';
        if (angle >= -112.5 && angle < -67.5) return '南';
        if (angle >= -67.5 && angle < -22.5) return '东南';
        return '前';
    }

    /**
     * 生成选项键
     * @param {Object} options - 选项对象
     * @returns {string} 选项键
     */
    generateOptionsKey(options) {
        if (!options || Object.keys(options).length === 0) {
            return 'default';
        }
        // 只包含重要的选项，忽略不重要的选项
        const importantOptions = ['strategy', 'waypoints', 'avoidpolygons', 'province', 'city'];
        const filteredOptions = {};
        importantOptions.forEach(key => {
            if (options[key] !== undefined && options[key] !== null) {
                filteredOptions[key] = options[key];
            }
        });
        return Object.keys(filteredOptions).length > 0 ? JSON.stringify(filteredOptions) : 'default';
    }

    /**
     * 构建请求URL
     * @param {Object} origin - 起点坐标
     * @param {Object} destination - 终点坐标
     * @param {string} mode - 交通方式
     * @param {Object} options - 可选参数
     * @returns {string} 完整的请求URL
     */
    buildUrl(origin, destination, mode, options) {
        const origins = `${origin.lng},${origin.lat}`;
        const destinations = `${destination.lng},${destination.lat}`;
        
        let url = `${this.baseUrl}/${mode}?key=${this.key}&origin=${origins}&destination=${destinations}`;
        
        // 添加可选参数
        if (options) {
            Object.entries(options).forEach(([key, value]) => {
                if (value !== undefined && value !== null) {
                    url += `&${key}=${encodeURIComponent(value)}`;
                }
            });
        }
        
        return url;
    }

    /**
     * 处理API响应数据
     * @param {Object} data - API响应数据
     * @param {string} mode - 交通方式
     * @returns {Object} 处理后的路径规划结果
     */
    processResponse(data, mode) {
        const result = {
            origin: data.origin,
            destination: data.destination,
            mode: mode,
            paths: [],
            timestamp: Date.now(),
            // 添加统计信息
            stats: {
                pathCount: 0,
                totalDistance: 0,
                totalDuration: 0
            }
        };

        // 根据交通方式处理路径数据
        switch (mode) {
            case 'walking':
                if (data.route && data.route.walking) {
                    data.route.walking.forEach(walking => {
                        if (walking.steps) {
                            const path = {
                                distance: walking.distance || 0,
                                duration: walking.duration || 0,
                                steps: walking.steps.map(step => ({
                                    instruction: step.instruction,
                                    orientation: step.orientation,
                                    road: step.road,
                                    distance: step.distance,
                                    duration: step.duration,
                                    polyline: step.polyline,
                                    action: step.action,
                                    assistant_action: step.assistant_action
                                }))
                            };
                            result.paths.push(path);
                            result.stats.pathCount++;
                            result.stats.totalDistance += parseInt(path.distance) || 0;
                            result.stats.totalDuration += parseInt(path.duration) || 0;
                        }
                    });
                }
                break;

            case 'driving':
                if (data.route && data.route.paths) {
                    data.route.paths.forEach(path => {
                        const drivingPath = {
                            distance: path.distance || 0,
                            duration: path.duration || 0,
                            tolls: path.tolls || 0,
                            toll_distance: path.toll_distance || 0,
                            steps: path.steps ? path.steps.map(step => ({
                                instruction: step.instruction,
                                orientation: step.orientation,
                                road: step.road,
                                distance: step.distance,
                                duration: step.duration,
                                polyline: step.polyline,
                                action: step.action,
                                assistant_action: step.assistant_action
                            })) : []
                        };
                        result.paths.push(drivingPath);
                        result.stats.pathCount++;
                        result.stats.totalDistance += parseInt(drivingPath.distance) || 0;
                        result.stats.totalDuration += parseInt(drivingPath.duration) || 0;
                    });
                }
                break;

            case 'transit':
                if (data.route && data.route.transits) {
                    data.route.transits.forEach(transit => {
                        const transitPath = {
                            distance: transit.distance || 0,
                            duration: transit.duration || 0,
                            cost: transit.cost || 0,
                            segments: transit.segments ? transit.segments.map(segment => ({
                                bus: segment.bus,
                                walking: segment.walking,
                                rail: segment.rail
                            })) : []
                        };
                        result.paths.push(transitPath);
                        result.stats.pathCount++;
                        result.stats.totalDistance += parseInt(transitPath.distance) || 0;
                        result.stats.totalDuration += parseInt(transitPath.duration) || 0;
                    });
                }
                break;
        }

        return result;
    }

    /**
     * 从缓存获取数据
     * @param {string} key - 缓存键
     * @returns {Object|null} 缓存的数据或null
     */
    getFromCache(key) {
        const cached = this.memoryCache.get(key);
        if (cached && (Date.now() - cached.timestamp) < this.memoryCacheExpiry) {
            return cached.data;
        }
        // 缓存过期，删除
        if (cached) {
            this.memoryCache.delete(key);
        }
        return null;
    }

    /**
     * 保存数据到缓存
     * @param {string} key - 缓存键
     * @param {Object} data - 要缓存的数据
     */
    saveToCache(key, data) {
        // 检查缓存大小，如果超过最大值，删除最旧的缓存
        if (this.memoryCache.size >= this.maxCacheSize) {
            this.evictOldestCache();
        }

        // 保存到内存缓存
        this.memoryCache.set(key, {
            data: data,
            timestamp: Date.now(),
            lastAccessed: Date.now()
        });
        
        // 保存到本地存储
        this.saveToLocalStorage();
        
        // 清理过期缓存
        this.cleanupCache();
    }

    /**
     * 保存缓存到本地存储
     */
    saveToLocalStorage() {
        try {
            if (typeof localStorage !== 'undefined') {
                const cacheData = {};
                this.memoryCache.forEach((value, key) => {
                    cacheData[key] = value;
                });
                localStorage.setItem(this.localStorageKey, JSON.stringify(cacheData));
            }
        } catch (error) {
            console.error('保存到本地存储失败:', error);
        }
    }

    /**
     * 删除最旧的缓存
     */
    evictOldestCache() {
        let oldestKey = null;
        let oldestTime = Date.now();
        
        this.memoryCache.forEach((value, key) => {
            if (value.timestamp < oldestTime) {
                oldestTime = value.timestamp;
                oldestKey = key;
            }
        });
        
        if (oldestKey) {
            this.memoryCache.delete(oldestKey);
            console.log('删除最旧的缓存:', oldestKey);
        }
    }

    /**
     * 清理过期缓存
     */
    cleanupCache() {
        const now = Date.now();
        let removedCount = 0;
        
        for (const [key, value] of this.memoryCache.entries()) {
            if (now - value.timestamp > this.memoryCacheExpiry) {
                this.memoryCache.delete(key);
                removedCount++;
            }
        }
        
        if (removedCount > 0) {
            console.log('清理过期缓存，删除了', removedCount, '个条目');
            // 更新本地存储
            this.saveToLocalStorage();
        }
    }

    /**
     * 清除所有缓存
     */
    clearCache() {
        this.memoryCache.clear();
        try {
            if (typeof localStorage !== 'undefined') {
                localStorage.removeItem(this.localStorageKey);
            }
        } catch (error) {
            console.error('清除本地缓存失败:', error);
        }
        console.log('缓存已清除');
    }

    /**
     * 获取缓存大小
     * @returns {number} 缓存条目数量
     */
    getCacheSize() {
        return this.memoryCache.size;
    }

    /**
     * 获取缓存统计信息
     * @returns {Object} 缓存统计信息
     */
    getCacheStats() {
        const now = Date.now();
        const stats = {
            total: this.memoryCache.size,
            expired: 0,
            valid: 0,
            age: {}
        };
        
        this.memoryCache.forEach((value, key) => {
            const age = now - value.timestamp;
            stats.age[key] = age;
            if (age < this.memoryCacheExpiry) {
                stats.valid++;
            } else {
                stats.expired++;
            }
        });
        
        return stats;
    }

    /**
     * 预加载常用路径
     * @param {Array} pathRequests - 路径请求数组
     */
    async preloadPaths(pathRequests) {
        if (!Array.isArray(pathRequests)) return;
        
        console.log('开始预加载路径规划结果');
        
        const promises = pathRequests.map(request => {
            return this.calculatePath(
                request.origin,
                request.destination,
                request.mode || 'walking',
                request.options || {}
            ).catch(error => {
                console.error('预加载路径失败:', error);
            });
        });
        
        await Promise.all(promises);
        console.log('路径预加载完成');
    }
}

/**
 * 创建路径规划服务实例
 * @param {string} key - 高德地图API密钥
 * @returns {PathPlanningService} 路径规划服务实例
 */
function createPathPlanningService(key) {
    return new PathPlanningService(key);
}

/**
 * 计算两点之间的直线距离（备用方案）
 * @param {Object} point1 - 第一个点 {lng, lat}
 * @param {Object} point2 - 第二个点 {lng, lat}
 * @returns {number} 距离（米）
 */
function calculateStraightDistance(point1, point2) {
    const R = 6371e3; // 地球半径（米）
    const φ1 = (point1.lat * Math.PI) / 180;
    const φ2 = (point2.lat * Math.PI) / 180;
    const Δφ = ((point2.lat - point1.lat) * Math.PI) / 180;
    const Δλ = ((point2.lng - point1.lng) * Math.PI) / 180;

    const a = Math.sin(Δφ / 2) * Math.sin(Δφ / 2) +
        Math.cos(φ1) * Math.cos(φ2) *
        Math.sin(Δλ / 2) * Math.sin(Δλ / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

    return R * c;
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        PathPlanningService,
        createPathPlanningService,
        calculateStraightDistance
    };
} else if (typeof window !== 'undefined') {
    window.PathPlanningService = PathPlanningService;
    window.createPathPlanningService = createPathPlanningService;
    window.calculateStraightDistance = calculateStraightDistance;
}
