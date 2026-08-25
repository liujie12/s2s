/**
 * 多级降级策略模块
 * 确保在不同网络环境下都能提供稳定的定位服务
 */

/**
 * 网络环境评估器
 * 评估当前网络环境，为降级策略提供依据
 */
class NetworkEnvironmentEvaluator {
    constructor() {
        this.networkDetector = new NetworkStateDetector();
    }

    /**
     * 评估当前网络环境
     * @returns {Promise<Object>} 网络环境评估结果
     */
    async evaluate() {
        const isOnline = this.networkDetector.isOnline();
        const connectionType = this.networkDetector.getConnectionType();
        const networkQuality = await this.networkDetector.getNetworkQuality();
        const latency = await this._measureLatency();
        const bandwidth = await this._estimateBandwidth();

        // 计算网络环境评分 (0-10，10最好)
        const score = this._calculateNetworkScore(isOnline, connectionType, networkQuality, latency, bandwidth);

        // 确定网络环境级别
        const level = this._determineNetworkLevel(score);

        return {
            isOnline,
            connectionType,
            networkQuality,
            latency,
            bandwidth,
            score,
            level,
            timestamp: Date.now()
        };
    }

    /**
     * 测量网络延迟
     * @returns {Promise<number>} 延迟时间（毫秒）
     * @private
     */
    async _measureLatency() {
        try {
            if (!this.networkDetector.isOnline()) {
                return Infinity;
            }

            // 模拟延迟测量
            // 实际项目中应通过ping测试或API调用测量
            return new Promise((resolve) => {
                setTimeout(() => {
                    // 模拟不同网络环境的延迟
                    const latencies = {
                        'wifi': Math.random() * 50 + 10,     // 10-60ms
                        '4g': Math.random() * 100 + 30,     // 30-130ms
                        '3g': Math.random() * 200 + 100,    // 100-300ms
                        '2g': Math.random() * 500 + 300,    // 300-800ms
                        'unknown': Math.random() * 200 + 50  // 50-250ms
                    };
                    
                    const connectionType = this.networkDetector.getConnectionType();
                    const latency = latencies[connectionType] || latencies.unknown;
                    resolve(latency);
                }, 50);
            });
        } catch (error) {
            console.warn('测量延迟失败:', error);
            return 500; // 默认延迟
        }
    }

    /**
     * 估计网络带宽
     * @returns {Promise<number>} 带宽（Mbps）
     * @private
     */
    async _estimateBandwidth() {
        try {
            if (!this.networkDetector.isOnline()) {
                return 0;
            }

            // 模拟带宽估计
            // 实际项目中应通过下载测试或navigator.connection.downlink估计
            return new Promise((resolve) => {
                setTimeout(() => {
                    // 模拟不同网络环境的带宽
                    const bandwidths = {
                        'wifi': Math.random() * 100 + 50,    // 50-150Mbps
                        '4g': Math.random() * 50 + 10,       // 10-60Mbps
                        '3g': Math.random() * 10 + 2,        // 2-12Mbps
                        '2g': Math.random() * 1 + 0.5,       // 0.5-1.5Mbps
                        'unknown': Math.random() * 30 + 5    // 5-35Mbps
                    };
                    
                    const connectionType = this.networkDetector.getConnectionType();
                    const bandwidth = bandwidths[connectionType] || bandwidths.unknown;
                    resolve(bandwidth);
                }, 30);
            });
        } catch (error) {
            console.warn('估计带宽失败:', error);
            return 2; // 默认带宽
        }
    }

    /**
     * 计算网络环境评分
     * @param {boolean} isOnline - 是否在线
     * @param {string} connectionType - 连接类型
     * @param {number} networkQuality - 网络质量评分
     * @param {number} latency - 延迟时间
     * @param {number} bandwidth - 带宽
     * @returns {number} 网络环境评分 (0-10)
     * @private
     */
    _calculateNetworkScore(isOnline, connectionType, networkQuality, latency, bandwidth) {
        if (!isOnline) {
            return 0;
        }

        // 网络质量评分 (0-5) 转换为 (0-4)
        const qualityScore = (networkQuality / 5) * 4;

        // 延迟评分 (0-3)，延迟越低评分越高
        let latencyScore = 3;
        if (latency > 500) latencyScore = 0;
        else if (latency > 300) latencyScore = 1;
        else if (latency > 100) latencyScore = 2;

        // 带宽评分 (0-3)，带宽越高评分越高
        let bandwidthScore = 0;
        if (bandwidth > 50) bandwidthScore = 3;
        else if (bandwidth > 10) bandwidthScore = 2;
        else if (bandwidth > 2) bandwidthScore = 1;

        // 总评分
        const totalScore = qualityScore + latencyScore + bandwidthScore;
        return Math.min(Math.round(totalScore), 10);
    }

    /**
     * 确定网络环境级别
     * @param {number} score - 网络环境评分
     * @returns {string} 网络环境级别
     * @private
     */
    _determineNetworkLevel(score) {
        if (score >= 9) return 'excellent';
        if (score >= 7) return 'good';
        if (score >= 5) return 'fair';
        if (score >= 3) return 'poor';
        if (score > 0) return 'very_poor';
        return 'offline';
    }
}

/**
 * 多级降级策略管理器
 * 管理不同网络环境下的定位服务降级策略
 */
class FallbackStrategyManager {
    constructor() {
        this.networkEvaluator = new NetworkEnvironmentEvaluator();
        this.currentNetworkLevel = 'unknown';
        this.lastEvaluationTime = 0;
        this.evaluationInterval = 30000; // 30秒评估一次网络环境
        this.strategyCache = new Map(); // 缓存策略结果
        this.maxCacheAge = 60000; // 策略缓存有效期1分钟
    }

    /**
     * 初始化降级策略管理器
     * @param {MultiSourceLocationService} locationService - 定位服务实例
     */
    initialize(locationService) {
        this.locationService = locationService;
        console.log('多级降级策略管理器初始化完成');
    }

    /**
     * 获取当前网络环境下的最佳定位策略
     * @returns {Promise<Object>} 定位策略
     */
    async getBestLocationStrategy() {
        // 检查是否需要重新评估网络环境
        const now = Date.now();
        if (now - this.lastEvaluationTime > this.evaluationInterval) {
            await this.evaluateNetworkEnvironment();
        }

        // 根据网络级别选择定位策略
        return this._selectLocationStrategy(this.currentNetworkLevel);
    }

    /**
     * 评估网络环境
     * @returns {Promise<Object>} 网络环境评估结果
     */
    async evaluateNetworkEnvironment() {
        const networkEnv = await this.networkEvaluator.evaluate();
        this.currentNetworkLevel = networkEnv.level;
        this.lastEvaluationTime = networkEnv.timestamp;
        
        console.log('网络环境评估结果:', networkEnv);
        return networkEnv;
    }

    /**
     * 根据网络级别选择定位策略
     * @param {string} networkLevel - 网络环境级别
     * @returns {Object} 定位策略
     * @private
     */
    _selectLocationStrategy(networkLevel) {
        // 检查缓存
        const cacheKey = networkLevel;
        const cachedStrategy = this.strategyCache.get(cacheKey);
        if (cachedStrategy && (Date.now() - cachedStrategy.timestamp) < this.maxCacheAge) {
            return cachedStrategy.strategy;
        }

        let strategy;
        switch (networkLevel) {
            case 'excellent':
                strategy = {
                    name: 'full_capability',
                    description: '完整能力模式 - 所有定位源都可用',
                    locationSources: ['GPS', 'Wi-Fi', 'Bluetooth', 'CellTower', 'IP'],
                    fusionEnabled: true,
                    highAccuracy: true,
                    updateFrequency: 1000, // 1秒更新一次
                    timeout: 5000
                };
                break;
            
            case 'good':
                strategy = {
                    name: 'high_performance',
                    description: '高性能模式 - 使用主要定位源',
                    locationSources: ['GPS', 'Wi-Fi', 'Bluetooth', 'CellTower'],
                    fusionEnabled: true,
                    highAccuracy: true,
                    updateFrequency: 2000, // 2秒更新一次
                    timeout: 7000
                };
                break;
            
            case 'fair':
                strategy = {
                    name: 'balanced',
                    description: '平衡模式 - 平衡性能和可靠性',
                    locationSources: ['Wi-Fi', 'Bluetooth', 'CellTower', 'GPS'],
                    fusionEnabled: true,
                    highAccuracy: false,
                    updateFrequency: 5000, // 5秒更新一次
                    timeout: 10000
                };
                break;
            
            case 'poor':
                strategy = {
                    name: 'reliability_focused',
                    description: '可靠性优先模式 - 使用可靠的定位源',
                    locationSources: ['CellTower', 'Wi-Fi', 'Bluetooth'],
                    fusionEnabled: false,
                    highAccuracy: false,
                    updateFrequency: 10000, // 10秒更新一次
                    timeout: 15000
                };
                break;
            
            case 'very_poor':
                strategy = {
                    name: 'minimal_mode',
                    description: '最小模式 - 使用最基本的定位源',
                    locationSources: ['CellTower', 'IP'],
                    fusionEnabled: false,
                    highAccuracy: false,
                    updateFrequency: 30000, // 30秒更新一次
                    timeout: 20000
                };
                break;
            
            case 'offline':
                strategy = {
                    name: 'offline_mode',
                    description: '离线模式 - 使用离线定位',
                    locationSources: ['Offline'],
                    fusionEnabled: false,
                    highAccuracy: false,
                    updateFrequency: 60000, // 60秒更新一次
                    timeout: 30000
                };
                break;
            
            default:
                strategy = {
                    name: 'default',
                    description: '默认模式 - 基本定位功能',
                    locationSources: ['GPS', 'Wi-Fi', 'CellTower', 'IP'],
                    fusionEnabled: true,
                    highAccuracy: false,
                    updateFrequency: 5000,
                    timeout: 10000
                };
                break;
        }

        // 缓存策略
        this.strategyCache.set(cacheKey, {
            strategy: strategy,
            timestamp: Date.now()
        });

        return strategy;
    }

    /**
     * 执行定位服务，根据网络环境自动选择策略
     * @param {Object} options - 定位选项
     * @returns {Promise<Object>} 定位结果
     */
    async executeLocation(options = {}) {
        const strategy = await this.getBestLocationStrategy();
        console.log('使用定位策略:', strategy.name, '-', strategy.description);

        try {
            // 根据策略调整定位选项
            const adjustedOptions = {
                ...options,
                timeout: strategy.timeout,
                enableHighAccuracy: strategy.highAccuracy
            };

            // 执行定位
            const locationData = await this.locationService.getFusedLocation(adjustedOptions);

            return {
                ...locationData,
                strategy: strategy.name,
                networkLevel: this.currentNetworkLevel
            };
        } catch (error) {
            console.warn('定位失败，尝试降级策略:', error.message);
            
            // 尝试降级策略
            return this._executeFallbackStrategy(error);
        }
    }

    /**
     * 执行降级策略
     * @param {Error} error - 原始错误
     * @returns {Promise<Object>} 降级后的定位结果
     * @private
     */
    async _executeFallbackStrategy(error) {
        // 强制重新评估网络环境
        await this.evaluateNetworkEnvironment();

        // 获取更低级别的策略
        const fallbackLevel = this._getFallbackNetworkLevel(this.currentNetworkLevel);
        const fallbackStrategy = this._selectLocationStrategy(fallbackLevel);

        console.log('执行降级策略:', fallbackStrategy.name, '-', fallbackStrategy.description);

        try {
            // 使用降级策略执行定位
            const adjustedOptions = {
                timeout: fallbackStrategy.timeout,
                enableHighAccuracy: fallbackStrategy.highAccuracy,
                forceRefresh: true
            };

            const locationData = await this.locationService.getFusedLocation(adjustedOptions);

            return {
                ...locationData,
                strategy: fallbackStrategy.name,
                networkLevel: fallbackLevel,
                fallback: true,
                originalError: error.message
            };
        } catch (fallbackError) {
            console.error('降级策略执行失败:', fallbackError.message);
            
            // 尝试使用缓存数据
            if (this.locationService && this.locationService.locationCache) {
                console.log('使用缓存的定位数据');
                return {
                    ...this.locationService.locationCache,
                    strategy: 'cache',
                    networkLevel: 'offline',
                    fallback: true,
                    fromCache: true,
                    errors: [error.message, fallbackError.message]
                };
            }

            throw fallbackError;
        }
    }

    /**
     * 获取降级后的网络级别
     * @param {string} currentLevel - 当前网络级别
     * @returns {string} 降级后的网络级别
     * @private
     */
    _getFallbackNetworkLevel(currentLevel) {
        const levels = ['excellent', 'good', 'fair', 'poor', 'very_poor', 'offline'];
        const currentIndex = levels.indexOf(currentLevel);
        
        if (currentIndex >= levels.length - 1) {
            return 'offline';
        }
        
        return levels[currentIndex + 1];
    }

    /**
     * 获取当前网络级别
     * @returns {string} 当前网络级别
     */
    getCurrentNetworkLevel() {
        return this.currentNetworkLevel;
    }

    /**
     * 手动触发网络环境评估
     * @returns {Promise<Object>} 网络环境评估结果
     */
    async triggerNetworkEvaluation() {
        return this.evaluateNetworkEnvironment();
    }
}

// 导出模块
const networkFallbackStrategy = {
    NetworkEnvironmentEvaluator,
    FallbackStrategyManager
};

// 全局变量，方便其他脚本使用
if (typeof window !== 'undefined') {
    window.networkFallbackStrategy = networkFallbackStrategy;
}

// 模块导出
if (typeof module !== 'undefined' && module.exports) {
    module.exports = networkFallbackStrategy;
}
