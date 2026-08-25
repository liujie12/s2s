/**
 * 离线定位功能模块
 * 在网络不可用时提供基础定位服务
 */

/**
 * 网络状态检测器
 */
class NetworkStateDetector {
    /**
     * 检测当前网络状态
     * @returns {boolean} 是否在线
     */
    isOnline() {
        if (typeof navigator !== 'undefined') {
            return navigator.onLine;
        }
        // 非浏览器环境默认认为在线
        return true;
    }

    /**
     * 检测网络连接类型
     * @returns {string} 网络连接类型
     */
    getConnectionType() {
        if (typeof navigator !== 'undefined' && navigator.connection) {
            return navigator.connection.type;
        }
        return 'unknown';
    }

    /**
     * 检测网络连接质量
     * @returns {Promise<number>} 网络质量评分 (0-5，5最好)
     */
    async getNetworkQuality() {
        // 模拟网络质量检测
        // 实际项目中可通过ping测试、DNS解析时间等方式评估
        return new Promise((resolve) => {
            setTimeout(() => {
                if (!this.isOnline()) {
                    resolve(0);
                } else {
                    // 随机生成网络质量评分，实际项目中应使用真实检测
                    resolve(Math.floor(Math.random() * 6));
                }
            }, 100);
        });
    }

    /**
     * 添加网络状态变化监听器
     * @param {Function} callback - 网络状态变化回调函数
     */
    addNetworkStateListener(callback) {
        if (typeof window !== 'undefined') {
            window.addEventListener('online', callback);
            window.addEventListener('offline', callback);
        }
    }

    /**
     * 移除网络状态变化监听器
     * @param {Function} callback - 要移除的回调函数
     */
    removeNetworkStateListener(callback) {
        if (typeof window !== 'undefined') {
            window.removeEventListener('online', callback);
            window.removeEventListener('offline', callback);
        }
    }
}

/**
 * 移动检测器
 * 检测用户移动情况，用于离线定位时调整位置
 */
class MovementDetector {
    constructor() {
        this.lastMovementTime = 0;
        this.lastAcceleration = null;
    }

    /**
     * 检测用户移动情况
     * @returns {Promise<Object>} 移动数据
     */
    async detectMovement() {
        try {
            // 尝试使用设备运动传感器
            if (typeof window !== 'undefined' && window.DeviceMotionEvent) {
                return await this._detectMovementWithSensors();
            }
        } catch (error) {
            console.warn('使用传感器检测移动失败:', error);
        }

        // 模拟移动检测
        return this._mockMovementDetection();
    }

    /**
     * 使用设备传感器检测移动
     * @returns {Promise<Object>} 移动数据
     * @private
     */
    _detectMovementWithSensors() {
        return new Promise((resolve) => {
            let movementDetected = false;
            let distance = 0;
            let direction = 0;
            
            const handleMotion = (event) => {
                const acceleration = event.accelerationIncludingGravity;
                
                if (this.lastAcceleration) {
                    // 计算加速度变化
                    const accChange = Math.sqrt(
                        Math.pow(acceleration.x - this.lastAcceleration.x, 2) +
                        Math.pow(acceleration.y - this.lastAcceleration.y, 2) +
                        Math.pow(acceleration.z - this.lastAcceleration.z, 2)
                    );
                    
                    // 如果加速度变化超过阈值，认为有移动
                    if (accChange > 1) {
                        movementDetected = true;
                        distance = Math.random() * 50; // 模拟移动距离
                        direction = Math.random() * 360; // 模拟移动方向
                    }
                }
                
                this.lastAcceleration = acceleration;
                this.lastMovementTime = Date.now();
                
                // 停止监听
                window.removeEventListener('devicemotion', handleMotion);
                
                resolve({
                    detected: movementDetected,
                    distance: distance,
                    direction: direction,
                    timestamp: Date.now()
                });
            };
            
            // 开始监听设备运动
            window.addEventListener('devicemotion', handleMotion, { once: true });
            
            // 3秒后超时
            setTimeout(() => {
                window.removeEventListener('devicemotion', handleMotion);
                resolve({
                    detected: false,
                    distance: 0,
                    direction: 0,
                    timestamp: Date.now()
                });
            }, 3000);
        });
    }

    /**
     * 模拟移动检测
     * @returns {Object} 模拟的移动数据
     * @private
     */
    _mockMovementDetection() {
        const currentTime = Date.now();
        const timeSinceLastMovement = currentTime - this.lastMovementTime;
        
        // 随机检测移动，时间间隔越长，检测到移动的概率越大
        const movementProbability = Math.min(timeSinceLastMovement / 60000, 0.8); // 最多80%的概率
        const detected = Math.random() < movementProbability;
        
        if (detected) {
            this.lastMovementTime = currentTime;
            return {
                detected: true,
                distance: Math.random() * 50, // 模拟移动距离
                direction: Math.random() * 360, // 模拟移动方向
                timestamp: currentTime
            };
        }
        
        return {
            detected: false,
            distance: 0,
            direction: 0,
            timestamp: currentTime
        };
    }

    /**
     * 重置移动检测状态
     */
    reset() {
        this.lastMovementTime = 0;
        this.lastAcceleration = null;
    }
}

/**
 * 离线定位源
 */
class OfflineLocationSource {
    constructor() {
        this.name = 'Offline';
        this.priority = 5; // 优先级较低，仅在其他定位源不可用时使用
        this.networkDetector = new NetworkStateDetector();
        this.storageKey = 'offline_location_cache';
        this.signalStorageKey = 'offline_signal_cache';
        this.movementDetector = new MovementDetector();
    }

    /**
     * 获取离线定位数据
     * @returns {Promise<Object>} 定位数据
     */
    async getLocation() {
        if (!this.isAvailable()) {
            throw new Error('离线定位不可用');
        }

        // 尝试从持久化存储获取最近的位置数据
        const cachedLocation = this._getCachedLocation();
        if (cachedLocation) {
            // 检测用户移动情况
            const movementData = await this.movementDetector.detectMovement();
            
            // 根据移动情况调整位置
            const adjustedLocation = this._adjustLocationForMovement(cachedLocation, movementData);
            
            // 尝试使用基站和Wi-Fi信号增强定位
            const enhancedLocation = await this._enhanceLocationWithSignals(adjustedLocation);
            
            return {
                ...enhancedLocation,
                source: this.name,
                timestamp: Date.now(),
                isOffline: true,
                movementDetected: movementData.detected
            };
        }

        // 如果没有缓存的位置数据，抛出错误
        throw new Error('没有可用的离线定位数据');
    }

    /**
     * 获取定位源名称
     * @returns {string} 定位源名称
     */
    getName() {
        return this.name;
    }

    /**
     * 获取定位源优先级
     * @returns {number} 优先级
     */
    getPriority() {
        return this.priority;
    }

    /**
     * 检查定位源是否可用
     * @returns {boolean} 是否可用
     */
    isAvailable() {
        // 离线定位源仅在网络不可用时可用
        return !this.networkDetector.isOnline() && this._hasCachedLocation();
    }

    /**
     * 缓存当前位置数据
     * @param {Object} locationData - 要缓存的位置数据
     */
    cacheLocation(locationData) {
        if (locationData && locationData.latitude && locationData.longitude) {
            const cacheData = {
                ...locationData,
                cachedAt: Date.now(),
                accuracy: locationData.accuracy || 100
            };
            this._saveToStorage(cacheData);
            
            // 缓存当前的信号数据
            this._cacheSignalData();
        }
    }

    /**
     * 从持久化存储获取缓存的位置数据
     * @private
     */
    _getCachedLocation() {
        try {
            if (typeof localStorage !== 'undefined') {
                const cachedData = localStorage.getItem(this.storageKey);
                if (cachedData) {
                    const locationData = JSON.parse(cachedData);
                    // 检查缓存是否过期（24小时）
                    const cacheAge = Date.now() - locationData.cachedAt;
                    const maxCacheAge = 24 * 60 * 60 * 1000; // 24小时
                    
                    if (cacheAge < maxCacheAge) {
                        return locationData;
                    }
                }
            }
        } catch (error) {
            console.warn('获取缓存位置数据失败:', error);
        }
        return null;
    }

    /**
     * 检查是否有缓存的位置数据
     * @private
     */
    _hasCachedLocation() {
        return this._getCachedLocation() !== null;
    }

    /**
     * 保存位置数据到持久化存储
     * @param {Object} locationData - 位置数据
     * @private
     */
    _saveToStorage(locationData) {
        try {
            if (typeof localStorage !== 'undefined') {
                localStorage.setItem(this.storageKey, JSON.stringify(locationData));
            }
        } catch (error) {
            console.warn('保存位置数据到存储失败:', error);
        }
    }

    /**
     * 清除缓存的位置数据
     */
    clearCache() {
        try {
            if (typeof localStorage !== 'undefined') {
                localStorage.removeItem(this.storageKey);
                localStorage.removeItem(this.signalStorageKey);
            }
        } catch (error) {
            console.warn('清除缓存位置数据失败:', error);
        }
    }

    /**
     * 根据移动情况调整位置
     * @param {Object} location - 原始位置数据
     * @param {Object} movementData - 移动数据
     * @returns {Object} 调整后的位置数据
     * @private
     */
    _adjustLocationForMovement(location, movementData) {
        if (!movementData.detected) {
            return location;
        }

        // 模拟根据移动距离和方向调整位置
        // 实际项目中应使用加速度传感器和陀螺仪数据
        const distance = movementData.distance || 0;
        const direction = movementData.direction || 0;
        
        // 计算位置偏移
        const latOffset = (distance / 111320) * Math.cos(direction * Math.PI / 180);
        const lonOffset = (distance / 111320) * Math.sin(direction * Math.PI / 180);
        
        return {
            ...location,
            latitude: location.latitude + latOffset,
            longitude: location.longitude + lonOffset,
            accuracy: location.accuracy + distance * 0.5, // 移动后精度降低
            movementAdjusted: true
        };
    }

    /**
     * 使用基站和Wi-Fi信号增强定位
     * @param {Object} location - 原始位置数据
     * @returns {Promise<Object>} 增强后的位置数据
     * @private
     */
    async _enhanceLocationWithSignals(location) {
        try {
            // 获取缓存的信号数据
            const signalData = this._getSignalData();
            
            if (signalData) {
                // 模拟信号强度对位置的影响
                // 实际项目中应使用真实的信号三角定位算法
                const signalQuality = this._calculateSignalQuality(signalData);
                
                // 信号质量好时，提高精度
                if (signalQuality > 3) {
                    return {
                        ...location,
                        accuracy: location.accuracy * 0.7,
                        signalEnhanced: true,
                        signalQuality: signalQuality
                    };
                }
            }
        } catch (error) {
            console.warn('信号增强定位失败:', error);
        }
        
        return location;
    }

    /**
     * 缓存信号数据
     * @private
     */
    _cacheSignalData() {
        try {
            // 模拟基站和Wi-Fi信号数据
            // 实际项目中应使用真实的信号扫描数据
            const signalData = {
                cellTowers: this._scanCellTowers(),
                wifiAccessPoints: this._scanWifiAccessPoints(),
                timestamp: Date.now()
            };
            
            if (typeof localStorage !== 'undefined') {
                localStorage.setItem(this.signalStorageKey, JSON.stringify(signalData));
            }
        } catch (error) {
            console.warn('缓存信号数据失败:', error);
        }
    }

    /**
     * 获取信号数据
     * @returns {Object|null} 信号数据
     * @private
     */
    _getSignalData() {
        try {
            if (typeof localStorage !== 'undefined') {
                const signalData = localStorage.getItem(this.signalStorageKey);
                if (signalData) {
                    const data = JSON.parse(signalData);
                    // 检查信号数据是否过期（1小时）
                    const signalAge = Date.now() - data.timestamp;
                    const maxSignalAge = 60 * 60 * 1000; // 1小时
                    
                    if (signalAge < maxSignalAge) {
                        return data;
                    }
                }
            }
        } catch (error) {
            console.warn('获取信号数据失败:', error);
        }
        return null;
    }

    /**
     * 模拟扫描基站
     * @returns {Array} 基站数据
     * @private
     */
    _scanCellTowers() {
        // 模拟基站数据
        return [
            {
                cellId: '12345',
                lac: '6789',
                signalStrength: Math.random() * 30 + 50 // 50-80 dBm
            },
            {
                cellId: '23456',
                lac: '7890',
                signalStrength: Math.random() * 30 + 40 // 40-70 dBm
            }
        ];
    }

    /**
     * 模拟扫描Wi-Fi接入点
     * @returns {Array} Wi-Fi接入点数据
     * @private
     */
    _scanWifiAccessPoints() {
        // 模拟Wi-Fi接入点数据
        return [
            {
                bssid: 'AA:BB:CC:DD:EE:FF',
                ssid: 'HomeWiFi',
                signalStrength: Math.random() * 30 + 50 // 50-80 dBm
            },
            {
                bssid: 'BB:CC:DD:EE:FF:AA',
                ssid: 'OfficeWiFi',
                signalStrength: Math.random() * 30 + 40 // 40-70 dBm
            }
        ];
    }

    /**
     * 计算信号质量
     * @param {Object} signalData - 信号数据
     * @returns {number} 信号质量评分 (0-5)
     * @private
     */
    _calculateSignalQuality(signalData) {
        let totalSignalStrength = 0;
        let signalCount = 0;
        
        // 计算基站信号强度
        if (signalData.cellTowers && signalData.cellTowers.length > 0) {
            signalData.cellTowers.forEach(tower => {
                totalSignalStrength += tower.signalStrength;
                signalCount++;
            });
        }
        
        // 计算Wi-Fi信号强度
        if (signalData.wifiAccessPoints && signalData.wifiAccessPoints.length > 0) {
            signalData.wifiAccessPoints.forEach(ap => {
                totalSignalStrength += ap.signalStrength;
                signalCount++;
            });
        }
        
        if (signalCount === 0) {
            return 0;
        }
        
        const averageSignalStrength = totalSignalStrength / signalCount;
        
        // 将信号强度转换为质量评分
        if (averageSignalStrength > 70) return 5;
        if (averageSignalStrength > 60) return 4;
        if (averageSignalStrength > 50) return 3;
        if (averageSignalStrength > 40) return 2;
        if (averageSignalStrength > 30) return 1;
        return 0;
    }
}

/**
 * 离线定位增强器
 * 增强现有定位系统的离线能力
 */
class OfflineLocationEnhancer {
    constructor() {
        this.networkDetector = new NetworkStateDetector();
        this.offlineLocationSource = new OfflineLocationSource();
        this.isOfflineMode = false;
        this.locationCache = null;
        this.cacheExpiryTime = 30000; // 缓存有效期30秒
        this.performanceStats = {
            offlineRequests: 0,
            successfulOfflineRequests: 0,
            averageOfflineResponseTime: 0,
            lastOfflineResponseTime: 0
        };
    }

    /**
     * 初始化离线定位增强器
     * @param {MultiSourceLocationService} locationService - 现有的定位服务实例
     */
    initialize(locationService) {
        this.locationService = locationService;
        
        // 添加离线定位源
        locationService.addLocationSource(this.offlineLocationSource);
        
        // 监听网络状态变化
        this.networkDetector.addNetworkStateListener(() => {
            this._handleNetworkStateChange();
        });
        
        // 初始化网络状态
        this._handleNetworkStateChange();
        
        console.log('离线定位增强器初始化完成');
    }

    /**
     * 处理网络状态变化
     * @private
     */
    _handleNetworkStateChange() {
        const newOfflineMode = !this.networkDetector.isOnline();
        if (newOfflineMode !== this.isOfflineMode) {
            this.isOfflineMode = newOfflineMode;
            console.log(`网络状态变化: ${this.isOfflineMode ? '离线' : '在线'}`);
            
            // 网络恢复时，清空缓存，重新获取最新位置
            if (!this.isOfflineMode) {
                this.clearCache();
            }
        }
    }

    /**
     * 增强定位请求
     * @param {Object} options - 定位选项
     * @returns {Promise<Object>} 增强后的定位数据
     */
    async enhanceLocationRequest(options = {}) {
        const startTime = Date.now();
        this.performanceStats.offlineRequests++;
        
        try {
            // 检查是否处于离线模式
            if (this.isOfflineMode) {
                console.log('使用离线定位模式');
                
                // 检查缓存
                if (!options.forceRefresh && this._isCacheValid()) {
                    this._updatePerformanceStats(Date.now() - startTime, true);
                    return {
                        ...this.locationCache,
                        fromCache: true
                    };
                }
                
                // 尝试使用离线定位源
                try {
                    const locationData = await this.offlineLocationSource.getLocation();
                    
                    // 更新缓存
                    this.locationCache = locationData;
                    this.locationCache.cachedAt = Date.now();
                    
                    this._updatePerformanceStats(Date.now() - startTime, true);
                    return locationData;
                } catch (error) {
                    console.warn('离线定位失败:', error);
                    // 尝试使用缓存的定位数据
                    if (this.locationService && this.locationService.locationCache) {
                        const cachedData = {
                            ...this.locationService.locationCache,
                            isOffline: true,
                            source: 'Cache',
                            error: error.message
                        };
                        this._updatePerformanceStats(Date.now() - startTime, true);
                        return cachedData;
                    }
                    throw error;
                }
            }
            
            // 在线模式，使用正常的定位流程
            const locationData = await this.locationService.getFusedLocation(options);
            
            // 缓存定位数据，为离线模式做准备
            this.offlineLocationSource.cacheLocation(locationData);
            
            this._updatePerformanceStats(Date.now() - startTime, true);
            return locationData;
        } catch (error) {
            console.error('增强定位请求失败:', error);
            this._updatePerformanceStats(Date.now() - startTime, false);
            throw error;
        }
    }

    /**
     * 检查缓存是否有效
     * @returns {boolean} 缓存是否有效
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
     * 更新性能统计
     * @param {number} responseTime - 响应时间
     * @param {boolean} success - 是否成功
     * @private
     */
    _updatePerformanceStats(responseTime, success) {
        this.performanceStats.lastOfflineResponseTime = responseTime;
        
        if (success) {
            this.performanceStats.successfulOfflineRequests++;
            const alpha = 0.1; // 平滑因子
            this.performanceStats.averageOfflineResponseTime = 
                this.performanceStats.averageOfflineResponseTime * (1 - alpha) + responseTime * alpha;
        }
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
        this.offlineLocationSource.clearCache();
    }

    /**
     * 获取当前网络状态
     * @returns {boolean} 是否在线
     */
    isOnline() {
        return this.networkDetector.isOnline();
    }

    /**
     * 获取网络连接类型
     * @returns {string} 网络连接类型
     */
    getConnectionType() {
        return this.networkDetector.getConnectionType();
    }

    /**
     * 获取网络质量
     * @returns {Promise<number>} 网络质量评分
     */
    async getNetworkQuality() {
        return this.networkDetector.getNetworkQuality();
    }
}

// 导出模块
const offlineLocation = {
    NetworkStateDetector,
    OfflineLocationSource,
    OfflineLocationEnhancer
};

// 全局变量，方便其他脚本使用
if (typeof window !== 'undefined') {
    window.offlineLocation = offlineLocation;
}

// 模块导出
if (typeof module !== 'undefined' && module.exports) {
    module.exports = offlineLocation;
}
