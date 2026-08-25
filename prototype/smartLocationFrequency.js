/**
 * 智能定位频率调整模块
 * 根据用户活动状态自动调整定位频率，平衡精度和电池消耗
 */

/**
 * 活动状态检测器
 * 检测用户的活动状态（静止、步行、跑步、驾驶）
 */
class ActivityStateDetector {
    /**
     * 构造函数
     * @param {Object} options - 选项
     * @param {number} options.minSpeedThreshold - 最小速度阈值（米/秒）
     * @param {number} options.walkingSpeedThreshold - 步行速度阈值（米/秒）
     * @param {number} options.runningSpeedThreshold - 跑步速度阈值（米/秒）
     * @param {number} options.historySize - 历史记录大小
     */
    constructor(options = {}) {
        this.minSpeedThreshold = options.minSpeedThreshold || 0.5; // 0.5 m/s
        this.walkingSpeedThreshold = options.walkingSpeedThreshold || 1.4; // 1.4 m/s
        this.runningSpeedThreshold = options.runningSpeedThreshold || 2.8; // 2.8 m/s
        this.historySize = options.historySize || 10;
        this.locationHistory = [];
        this.lastActivityState = 'stationary';
        this.activityConfidence = 0;
    }
    
    /**
     * 检测活动状态
     * @param {Object} currentLocation - 当前位置
     * @returns {Object} 活动状态信息
     */
    detectActivityState(currentLocation) {
        if (!currentLocation || !currentLocation.latitude || !currentLocation.longitude) {
            return {
                state: this.lastActivityState,
                confidence: 0.5,
                speed: 0
            };
        }
        
        // 添加当前位置到历史记录
        this.locationHistory.push({
            latitude: currentLocation.latitude,
            longitude: currentLocation.longitude,
            timestamp: currentLocation.timestamp || Date.now()
        });
        
        // 保持历史记录大小
        if (this.locationHistory.length > this.historySize) {
            this.locationHistory.shift();
        }
        
        // 计算速度和活动状态
        const { speed, state, confidence } = this._calculateActivityState();
        
        this.lastActivityState = state;
        this.activityConfidence = confidence;
        
        return {
            state,
            confidence,
            speed
        };
    }
    
    /**
     * 计算活动状态
     * @private
     * @returns {Object} 活动状态信息
     */
    _calculateActivityState() {
        if (this.locationHistory.length < 2) {
            return {
                speed: 0,
                state: 'stationary',
                confidence: 0.3
            };
        }
        
        // 计算最近位置之间的平均速度
        let totalDistance = 0;
        let totalTime = 0;
        
        for (let i = 1; i < this.locationHistory.length; i++) {
            const prev = this.locationHistory[i - 1];
            const curr = this.locationHistory[i];
            
            const distance = this._calculateDistance(
                prev.latitude, prev.longitude,
                curr.latitude, curr.longitude
            );
            const time = (curr.timestamp - prev.timestamp) / 1000; // 转换为秒
            
            totalDistance += distance;
            totalTime += time;
        }
        
        const speed = totalTime > 0 ? totalDistance / totalTime : 0;
        let state, confidence;
        
        // 根据速度确定活动状态
        if (speed < this.minSpeedThreshold) {
            state = 'stationary';
            confidence = Math.min(1, 0.7 + (1 - speed / this.minSpeedThreshold) * 0.3);
        } else if (speed < this.walkingSpeedThreshold) {
            state = 'walking';
            confidence = Math.min(1, 0.6 + (speed - this.minSpeedThreshold) / (this.walkingSpeedThreshold - this.minSpeedThreshold) * 0.4);
        } else if (speed < this.runningSpeedThreshold) {
            state = 'running';
            confidence = Math.min(1, 0.6 + (speed - this.walkingSpeedThreshold) / (this.runningSpeedThreshold - this.walkingSpeedThreshold) * 0.4);
        } else {
            state = 'driving';
            confidence = Math.min(1, 0.7 + (speed - this.runningSpeedThreshold) / 10 * 0.3);
        }
        
        return { speed, state, confidence };
    }
    
    /**
     * 计算两点之间的距离
     * @private
     * @param {number} lat1 - 第一个点的纬度
     * @param {number} lon1 - 第一个点的经度
     * @param {number} lat2 - 第二个点的纬度
     * @param {number} lon2 - 第二个点的经度
     * @returns {number} 距离（米）
     */
    _calculateDistance(lat1, lon1, lat2, lon2) {
        const R = 6371000; // 地球半径（米）
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
     * 清空历史记录
     */
    clearHistory() {
        this.locationHistory = [];
        this.lastActivityState = 'stationary';
        this.activityConfidence = 0;
    }
    
    /**
     * 获取最后检测的活动状态
     * @returns {string} 活动状态
     */
    getLastActivityState() {
        return this.lastActivityState;
    }
}

/**
 * 电池优化器
 * 优化电池消耗
 */
class BatteryOptimizer {
    /**
     * 构造函数
     * @param {Object} options - 选项
     * @param {number} options.lowBatteryThreshold - 低电池阈值（百分比）
     * @param {number} options.criticalBatteryThreshold - 临界电池阈值（百分比）
     */
    constructor(options = {}) {
        this.lowBatteryThreshold = options.lowBatteryThreshold || 30;
        this.criticalBatteryThreshold = options.criticalBatteryThreshold || 15;
        this.lastBatteryLevel = 100;
        this.batteryStatus = 'normal';
    }
    
    /**
     * 检测电池状态
     * @returns {Object} 电池状态信息
     */
    detectBatteryStatus() {
        let batteryLevel = 100;
        
        // 尝试使用浏览器的电池API
        if (typeof navigator !== 'undefined' && navigator.getBattery) {
            return new Promise((resolve) => {
                navigator.getBattery().then((battery) => {
                    batteryLevel = battery.level * 100;
                    const status = this._determineBatteryStatus(batteryLevel);
                    resolve({ level: batteryLevel, status });
                }).catch(() => {
                    // 模拟电池状态
                    batteryLevel = this._mockBatteryLevel();
                    const status = this._determineBatteryStatus(batteryLevel);
                    resolve({ level: batteryLevel, status });
                });
            });
        } else {
            // 模拟电池状态
            batteryLevel = this._mockBatteryLevel();
            const status = this._determineBatteryStatus(batteryLevel);
            return Promise.resolve({ level: batteryLevel, status });
        }
    }
    
    /**
     * 模拟电池状态
     * @private
     * @returns {number} 电池电量百分比
     */
    _mockBatteryLevel() {
        // 模拟电池电量，随机波动但保持在合理范围内
        const variation = (Math.random() - 0.5) * 2;
        this.lastBatteryLevel = Math.max(5, Math.min(100, this.lastBatteryLevel + variation));
        return this.lastBatteryLevel;
    }
    
    /**
     * 确定电池状态
     * @private
     * @param {number} batteryLevel - 电池电量百分比
     * @returns {string} 电池状态
     */
    _determineBatteryStatus(batteryLevel) {
        if (batteryLevel <= this.criticalBatteryThreshold) {
            this.batteryStatus = 'critical';
        } else if (batteryLevel <= this.lowBatteryThreshold) {
            this.batteryStatus = 'low';
        } else {
            this.batteryStatus = 'normal';
        }
        return this.batteryStatus;
    }
    
    /**
     * 获取电池优化建议
     * @param {number} batteryLevel - 电池电量百分比
     * @returns {Object} 优化建议
     */
    getOptimizationSuggestion(batteryLevel) {
        const status = this._determineBatteryStatus(batteryLevel);
        
        switch (status) {
            case 'critical':
                return {
                    reduceFrequency: true,
                    maxFrequency: 60000, // 1分钟
                    useLowPowerMode: true
                };
            case 'low':
                return {
                    reduceFrequency: true,
                    maxFrequency: 30000, // 30秒
                    useLowPowerMode: false
                };
            default:
                return {
                    reduceFrequency: false,
                    maxFrequency: null,
                    useLowPowerMode: false
                };
        }
    }
    
    /**
     * 获取最后检测的电池状态
     * @returns {string} 电池状态
     */
    getLastBatteryStatus() {
        return this.batteryStatus;
    }
}

/**
 * 定位频率管理器
 * 管理定位频率调整
 */
class LocationFrequencyManager {
    /**
     * 构造函数
     * @param {Object} options - 选项
     * @param {ActivityStateDetector} options.activityDetector - 活动状态检测器
     * @param {BatteryOptimizer} options.batteryOptimizer - 电池优化器
     */
    constructor(options = {}) {
        this.activityDetector = options.activityDetector || new ActivityStateDetector();
        this.batteryOptimizer = options.batteryOptimizer || new BatteryOptimizer();
        
        // 默认定位频率（毫秒）
        this.defaultFrequencies = {
            stationary: 300000, // 5分钟
            walking: 60000,     // 1分钟
            running: 30000,     // 30秒
            driving: 10000      // 10秒
        };
        
        // 当前频率
        this.currentFrequency = this.defaultFrequencies.stationary;
        this.lastLocation = null;
        this.performanceStats = {
            totalAdjustments: 0,
            averageFrequency: this.currentFrequency,
            batterySavings: 0,
            lastAdjustmentTime: 0
        };
    }
    
    /**
     * 调整定位频率
     * @param {Object} location - 当前位置
     * @returns {Promise<number>} 调整后的频率（毫秒）
     */
    async adjustFrequency(location) {
        // 检测活动状态
        const activityInfo = this.activityDetector.detectActivityState(location);
        
        // 检测电池状态
        const batteryInfo = await this.batteryOptimizer.detectBatteryStatus();
        
        // 计算基础频率
        let baseFrequency = this.defaultFrequencies[activityInfo.state] || this.defaultFrequencies.stationary;
        
        // 应用电池优化
        const batterySuggestion = this.batteryOptimizer.getOptimizationSuggestion(batteryInfo.level);
        if (batterySuggestion.reduceFrequency) {
            baseFrequency = Math.max(baseFrequency, batterySuggestion.maxFrequency);
        }
        
        // 根据活动状态置信度调整频率
        const confidenceFactor = 0.5 + (activityInfo.confidence * 0.5);
        const adjustedFrequency = Math.round(baseFrequency * confidenceFactor);
        
        // 限制频率范围
        const minFrequency = 5000; // 最小5秒
        const maxFrequency = 600000; // 最大10分钟
        this.currentFrequency = Math.max(minFrequency, Math.min(maxFrequency, adjustedFrequency));
        
        // 更新性能统计
        this._updatePerformanceStats(this.currentFrequency, batteryInfo);
        
        this.lastLocation = location;
        
        return this.currentFrequency;
    }
    
    /**
     * 更新性能统计
     * @private
     * @param {number} frequency - 当前频率
     * @param {Object} batteryInfo - 电池信息
     */
    _updatePerformanceStats(frequency, batteryInfo) {
        this.performanceStats.totalAdjustments++;
        this.performanceStats.averageFrequency = 
            (this.performanceStats.averageFrequency * (this.performanceStats.totalAdjustments - 1) + frequency) / 
            this.performanceStats.totalAdjustments;
        
        // 计算电池节省
        const baseFrequency = this.defaultFrequencies.stationary;
        const batterySavingPercent = Math.max(0, (baseFrequency - frequency) / baseFrequency * 100);
        this.performanceStats.batterySavings = 
            (this.performanceStats.batterySavings * (this.performanceStats.totalAdjustments - 1) + batterySavingPercent) / 
            this.performanceStats.totalAdjustments;
        
        this.performanceStats.lastAdjustmentTime = Date.now();
    }
    
    /**
     * 获取当前定位频率
     * @returns {number} 当前频率（毫秒）
     */
    getCurrentFrequency() {
        return this.currentFrequency;
    }
    
    /**
     * 获取性能统计
     * @returns {Object} 性能统计
     */
    getPerformanceStats() {
        return { ...this.performanceStats };
    }
    
    /**
     * 获取建议的定位频率
     * @param {string} activityState - 活动状态
     * @param {number} batteryLevel - 电池电量
     * @returns {number} 建议的频率（毫秒）
     */
    getSuggestedFrequency(activityState, batteryLevel) {
        let baseFrequency = this.defaultFrequencies[activityState] || this.defaultFrequencies.stationary;
        
        const batterySuggestion = this.batteryOptimizer.getOptimizationSuggestion(batteryLevel);
        if (batterySuggestion.reduceFrequency) {
            baseFrequency = Math.max(baseFrequency, batterySuggestion.maxFrequency);
        }
        
        return baseFrequency;
    }
}

/**
 * 智能定位频率调整服务
 * 整合所有组件，提供智能定位频率调整功能
 */
class SmartLocationFrequencyService {
    /**
     * 构造函数
     * @param {Object} options - 选项
     */
    constructor(options = {}) {
        this.activityDetector = new ActivityStateDetector(options.activityDetectorOptions);
        this.batteryOptimizer = new BatteryOptimizer(options.batteryOptimizerOptions);
        this.frequencyManager = new LocationFrequencyManager({
            activityDetector: this.activityDetector,
            batteryOptimizer: this.batteryOptimizer
        });
        
        this.isInitialized = false;
    }
    
    /**
     * 初始化服务
     */
    initialize() {
        this.isInitialized = true;
        console.log('智能定位频率调整服务初始化成功');
    }
    
    /**
     * 调整定位频率
     * @param {Object} location - 当前位置
     * @returns {Promise<number>} 调整后的频率（毫秒）
     */
    async adjustLocationFrequency(location) {
        if (!this.isInitialized) {
            this.initialize();
        }
        
        return this.frequencyManager.adjustFrequency(location);
    }
    
    /**
     * 检测活动状态
     * @param {Object} location - 当前位置
     * @returns {Object} 活动状态信息
     */
    detectActivityState(location) {
        return this.activityDetector.detectActivityState(location);
    }
    
    /**
     * 检测电池状态
     * @returns {Promise<Object>} 电池状态信息
     */
    detectBatteryStatus() {
        return this.batteryOptimizer.detectBatteryStatus();
    }
    
    /**
     * 获取当前定位频率
     * @returns {number} 当前频率（毫秒）
     */
    getCurrentFrequency() {
        return this.frequencyManager.getCurrentFrequency();
    }
    
    /**
     * 获取性能统计
     * @returns {Object} 性能统计
     */
    getPerformanceStats() {
        return {
            frequency: this.frequencyManager.getPerformanceStats(),
            lastActivityState: this.activityDetector.getLastActivityState(),
            lastBatteryStatus: this.batteryOptimizer.getLastBatteryStatus()
        };
    }
    
    /**
     * 重置服务
     */
    reset() {
        this.activityDetector.clearHistory();
        this.isInitialized = false;
    }
}

// 导出模块
const smartLocationFrequency = {
    ActivityStateDetector,
    BatteryOptimizer,
    LocationFrequencyManager,
    SmartLocationFrequencyService
};

// 全局变量，方便其他脚本使用
if (typeof window !== 'undefined') {
    window.smartLocationFrequency = smartLocationFrequency;
    
    // 创建默认服务实例
    const smartFrequencyService = new SmartLocationFrequencyService();
    window.smartFrequencyService = smartFrequencyService;
    
    console.log('智能定位频率调整模块加载成功');
    
    // 延迟加载，与现有定位系统集成
    setTimeout(async () => {
        try {
            // 尝试与多源定位服务集成
            if (window.locationService) {
                const originalGetFusedLocation = window.locationService.getFusedLocation;
                
                // 增强定位服务，添加智能频率调整支持
                window.locationService.adjustLocationFrequency = async (location) => {
                    return smartFrequencyService.adjustLocationFrequency(location);
                };
                
                window.locationService.getSmartFrequencyStats = () => {
                    return smartFrequencyService.getPerformanceStats();
                };
                
                console.log('智能定位频率调整服务与定位服务集成成功');
            }
            
            // 尝试与实时更新管理器集成
            if (window.RealTimeUpdateManager && window.locationService && window.locationService.realTimeUpdateManager) {
                const originalStart = window.locationService.realTimeUpdateManager.start;
                
                // 增强实时更新管理器，添加智能频率调整
                window.locationService.realTimeUpdateManager.start = async (options = {}) => {
                    // 启动时检测初始频率
                    if (window.locationService.locationCache) {
                        const initialFrequency = await smartFrequencyService.adjustLocationFrequency(
                            window.locationService.locationCache
                        );
                        options.frequency = initialFrequency;
                    }
                    
                    // 启动实时更新
                    const result = await originalStart.call(window.locationService.realTimeUpdateManager, options);
                    
                    // 监听位置更新，动态调整频率
                    window.addEventListener('locationUpdated', async (event) => {
                        const newFrequency = await smartFrequencyService.adjustLocationFrequency(event.detail);
                        window.locationService.realTimeUpdateManager.updateFrequency(newFrequency);
                    });
                    
                    return result;
                };
                
                console.log('智能定位频率调整服务与实时更新管理器集成成功');
            }
        } catch (error) {
            console.warn('智能定位频率调整服务集成失败:', error);
        }
    }, 2500);
}

// 模块导出
if (typeof module !== 'undefined' && module.exports) {
    module.exports = smartLocationFrequency;
}
