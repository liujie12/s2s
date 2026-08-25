/**
 * 实时更新机制模块
 * 实现位置信息的实时更新，确保资源位置信息的准确性和时效性
 */

/**
 * 实时更新管理器
 * 负责管理位置信息的实时更新，包括更新频率控制、触发条件检测和数据同步
 */
class RealTimeUpdateManager {
    /**
     * 构造函数
     * @param {Object} options - 配置选项
     * @param {number} options.defaultUpdateInterval - 默认更新间隔（毫秒）
     * @param {number} options.minUpdateInterval - 最小更新间隔（毫秒）
     * @param {number} options.maxUpdateInterval - 最大更新间隔（毫秒）
     * @param {number} options.movementThreshold - 位置变化阈值（米）
     * @param {Function} options.locationProvider - 位置提供者函数，返回Promise<Object>定位数据
     * @param {Function} options.updateCallback - 更新回调函数，接收最新的位置数据
     */
    constructor(options = {}) {
        // 配置选项
        this.defaultUpdateInterval = options.defaultUpdateInterval || 10000; // 默认10秒更新一次
        this.minUpdateInterval = options.minUpdateInterval || 2000; // 最小2秒更新一次
        this.maxUpdateInterval = options.maxUpdateInterval || 60000; // 最大60秒更新一次
        this.movementThreshold = options.movementThreshold || 10; // 位置变化超过10米时更新
        
        // 依赖项
        this.locationProvider = options.locationProvider;
        this.updateCallback = options.updateCallback;
        
        // 状态管理
        this.isRunning = false;
        this.updateTimer = null;
        this.lastLocation = null;
        this.lastUpdateTime = 0;
        this.currentUpdateInterval = this.defaultUpdateInterval;
        
        // 活动状态检测
        this.activityDetector = new ActivityDetector();
        this.currentActivityState = 'stationary'; // stationary, walking, running, driving
        
        // 网络条件检测
        this.networkDetector = new NetworkDetector();
        this.currentNetworkQuality = 'good'; // good, moderate, poor
        
        // 电池状态检测
        this.batteryDetector = new BatteryDetector();
        this.currentBatteryStatus = 'high'; // high, medium, low
        
        // 性能统计
        this.performanceStats = {
            totalUpdates: 0,
            successfulUpdates: 0,
            failedUpdates: 0,
            averageUpdateTime: 0,
            lastUpdateTime: 0
        };
    }
    
    /**
     * 开始实时更新
     * @returns {Promise<void>}
     */
    async start() {
        if (this.isRunning) {
            console.log('实时更新已经在运行中');
            return;
        }
        
        console.log('开始实时更新...');
        this.isRunning = true;
        
        // 立即执行一次更新
        await this.updateLocation();
        
        // 启动更新定时器
        this._scheduleNextUpdate();
    }
    
    /**
     * 停止实时更新
     */
    stop() {
        if (!this.isRunning) {
            console.log('实时更新已经停止');
            return;
        }
        
        console.log('停止实时更新...');
        this.isRunning = false;
        
        // 清除更新定时器
        if (this.updateTimer) {
            clearTimeout(this.updateTimer);
            this.updateTimer = null;
        }
    }
    
    /**
     * 手动触发位置更新
     * @returns {Promise<Object>} 最新的位置数据
     */
    async updateLocation() {
        const startTime = Date.now();
        
        try {
            // 获取最新位置
            const location = await this.locationProvider();
            
            // 更新活动检测器的位置信息，用于更准确的活动状态检测
            this.activityDetector.updatePosition(location);
            
            // 检查位置是否发生显著变化
            const shouldUpdate = this._shouldUpdateLocation(location);
            
            if (shouldUpdate) {
                // 更新最后位置和时间
                this.lastLocation = location;
                this.lastUpdateTime = Date.now();
                
                // 调用更新回调
                if (this.updateCallback) {
                    this.updateCallback(location);
                }
                
                // 更新性能统计
                this.performanceStats.successfulUpdates++;
                this.performanceStats.lastUpdateTime = Date.now() - startTime;
                this._updateAverageUpdateTime(this.performanceStats.lastUpdateTime);
                
                console.log('位置更新成功:', location);
            }
            
            // 更新性能统计
            this.performanceStats.totalUpdates++;
            
            return location;
        } catch (error) {
            console.error('位置更新失败:', error);
            
            // 更新性能统计
            this.performanceStats.totalUpdates++;
            this.performanceStats.failedUpdates++;
            
            throw error;
        }
    }
    
    /**
     * 智能调整更新频率
     * @returns {number} 调整后的更新间隔（毫秒）
     */
    _adjustUpdateInterval() {
        // 检测活动状态
        this.currentActivityState = this.activityDetector.detectActivityState();
        
        // 检测网络质量
        this.currentNetworkQuality = this.networkDetector.detectNetworkQuality();
        
        // 检测电池状态
        const batteryState = this.batteryDetector.getBatteryState();
        this.currentBatteryStatus = batteryState.status;
        
        // 根据活动状态调整基础频率
        let baseInterval;
        switch (this.currentActivityState) {
            case 'driving':
                baseInterval = this.minUpdateInterval; // 快速移动时最高频率
                break;
            case 'running':
                baseInterval = this.minUpdateInterval * 2; // 跑步时较高频率
                break;
            case 'walking':
                baseInterval = this.defaultUpdateInterval; // 步行时默认频率
                break;
            case 'stationary':
            default:
                baseInterval = this.maxUpdateInterval; // 静止时最低频率
                break;
        }
        
        // 根据网络质量调整频率
        let networkAdjustment;
        switch (this.currentNetworkQuality) {
            case 'good':
                networkAdjustment = 1.0; // 网络好时正常频率
                break;
            case 'moderate':
                networkAdjustment = 1.5; // 网络一般时降低频率
                break;
            case 'poor':
                networkAdjustment = 2.0; // 网络差时大幅降低频率
                break;
            default:
                networkAdjustment = 1.0;
        }
        
        // 根据电池状态调整频率
        let batteryAdjustment = 1.0;
        if (!batteryState.isCharging) {
            switch (this.currentBatteryStatus) {
                case 'high':
                    batteryAdjustment = 1.0; // 电池高时正常频率
                    break;
                case 'medium':
                    batteryAdjustment = 1.2; // 电池中等时略微降低频率
                    break;
                case 'low':
                    batteryAdjustment = 1.5; // 电池低时显著降低频率
                    break;
                default:
                    batteryAdjustment = 1.0;
            }
        }
        
        // 计算最终更新间隔
        let finalInterval = baseInterval * networkAdjustment * batteryAdjustment;
        
        // 确保更新间隔在有效范围内
        finalInterval = Math.max(this.minUpdateInterval, Math.min(this.maxUpdateInterval, finalInterval));
        
        this.currentUpdateInterval = finalInterval;
        console.log(`调整更新频率: ${this.currentActivityState}状态, ${this.currentNetworkQuality}网络, ${this.currentBatteryStatus}电池${batteryState.isCharging ? '(充电中)' : ''}, 间隔${Math.round(finalInterval/1000)}秒`);
        
        return finalInterval;
    }
    
    /**
     * 检查是否应该更新位置
     * @param {Object} newLocation - 新的位置数据
     * @returns {boolean} 是否应该更新
     */
    _shouldUpdateLocation(newLocation) {
        // 如果是第一次更新，直接返回true
        if (!this.lastLocation) {
            return true;
        }
        
        // 检查时间间隔
        const timeElapsed = Date.now() - this.lastUpdateTime;
        if (timeElapsed >= this.currentUpdateInterval) {
            return true;
        }
        
        // 检查位置变化
        const distance = this._calculateDistance(
            this.lastLocation.latitude, this.lastLocation.longitude,
            newLocation.latitude, newLocation.longitude
        );
        
        if (distance >= this.movementThreshold) {
            return true;
        }
        
        return false;
    }
    
    /**
     * 计算两个坐标点之间的距离（米）
     * @param {number} lat1 - 第一个点的纬度
     * @param {number} lon1 - 第一个点的经度
     * @param {number} lat2 - 第二个点的纬度
     * @param {number} lon2 - 第二个点的经度
     * @returns {number} 距离（米）
     */
    _calculateDistance(lat1, lon1, lat2, lon2) {
        const R = 6371e3; // 地球半径（米）
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
     * 安排下一次更新
     * @private
     */
    _scheduleNextUpdate() {
        if (!this.isRunning) {
            return;
        }
        
        // 调整更新频率
        const interval = this._adjustUpdateInterval();
        
        // 安排下一次更新
        this.updateTimer = setTimeout(async () => {
            try {
                await this.updateLocation();
            } catch (error) {
                console.error('定时更新失败:', error);
            } finally {
                // 无论成功失败，都安排下一次更新
                this._scheduleNextUpdate();
            }
        }, interval);
    }
    
    /**
     * 更新平均更新时间
     * @param {number} updateTime - 本次更新时间（毫秒）
     * @private
     */
    _updateAverageUpdateTime(updateTime) {
        const total = this.performanceStats.successfulUpdates;
        if (total === 1) {
            this.performanceStats.averageUpdateTime = updateTime;
        } else {
            this.performanceStats.averageUpdateTime = (
                this.performanceStats.averageUpdateTime * (total - 1) + updateTime
            ) / total;
        }
    }
    
    /**
     * 获取性能统计信息
     * @returns {Object} 性能统计信息
     */
    getPerformanceStats() {
        return { ...this.performanceStats };
    }
    
    /**
     * 获取当前状态
     * @returns {Object} 当前状态
     */
    getCurrentState() {
        return {
            isRunning: this.isRunning,
            currentUpdateInterval: this.currentUpdateInterval,
            lastLocation: this.lastLocation,
            lastUpdateTime: this.lastUpdateTime,
            currentActivityState: this.currentActivityState,
            currentNetworkQuality: this.currentNetworkQuality,
            currentBatteryStatus: this.currentBatteryStatus,
            batteryState: this.batteryDetector.getBatteryState(),
            performanceStats: this.getPerformanceStats()
        };
    }
}

/**
 * 活动状态检测器
 * 检测用户的活动状态，如静止、步行、跑步、驾驶等
 */
class ActivityDetector {
    constructor() {
        // 活动状态历史记录
        this.activityHistory = [];
        this.historySize = 5;
        
        // 速度阈值（米/秒）
        this.speedThresholds = {
            stationary: 0.5,
            walking: 2.0,
            running: 5.0,
            driving: 10.0
        };
        
        // 上次位置
        this.lastPosition = null;
        this.lastTimestamp = null;
    }
    
    /**
     * 更新位置信息，用于活动状态检测
     * @param {Object} position - 位置信息
     */
    updatePosition(position) {
        if (this.lastPosition && this.lastTimestamp) {
            const distance = this._calculateDistance(
                this.lastPosition.latitude, this.lastPosition.longitude,
                position.latitude, position.longitude
            );
            const timeDiff = (position.timestamp || Date.now()) - this.lastTimestamp;
            const speed = distance / (timeDiff / 1000); // 米/秒
            
            // 根据速度判断活动状态
            let activityState;
            if (speed < this.speedThresholds.stationary) {
                activityState = 'stationary';
            } else if (speed < this.speedThresholds.walking) {
                activityState = 'walking';
            } else if (speed < this.speedThresholds.running) {
                activityState = 'running';
            } else {
                activityState = 'driving';
            }
            
            // 添加到历史记录
            this.activityHistory.push(activityState);
            if (this.activityHistory.length > this.historySize) {
                this.activityHistory.shift();
            }
        }
        
        this.lastPosition = position;
        this.lastTimestamp = position.timestamp || Date.now();
    }
    
    /**
     * 检测活动状态
     * @returns {string} 活动状态：stationary, walking, running, driving
     */
    detectActivityState() {
        // 如果有历史记录，使用最常见的活动状态
        if (this.activityHistory.length > 0) {
            const stateCount = {};
            for (const state of this.activityHistory) {
                stateCount[state] = (stateCount[state] || 0) + 1;
            }
            
            let mostFrequentState = 'stationary';
            let maxCount = 0;
            
            for (const [state, count] of Object.entries(stateCount)) {
                if (count > maxCount) {
                    maxCount = count;
                    mostFrequentState = state;
                }
            }
            
            return mostFrequentState;
        }
        
        // 否则使用模拟数据
        return this._mockActivityState();
    }
    
    /**
     * 模拟活动状态检测
     * @private
     */
    _mockActivityState() {
        const states = ['stationary', 'walking', 'running', 'driving'];
        const probabilities = [0.6, 0.25, 0.1, 0.05]; // 静止概率最高
        
        let rand = Math.random();
        let cumulativeProbability = 0;
        
        for (let i = 0; i < states.length; i++) {
            cumulativeProbability += probabilities[i];
            if (rand <= cumulativeProbability) {
                return states[i];
            }
        }
        
        return 'stationary';
    }
    
    /**
     * 计算两个坐标点之间的距离（米）
     * @private
     */
    _calculateDistance(lat1, lon1, lat2, lon2) {
        const R = 6371e3; // 地球半径（米）
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
}

/**
 * 网络质量检测器
 * 检测网络质量，如良好、一般、较差等
 */
class NetworkDetector {
    /**
     * 检测网络质量
     * @returns {string} 网络质量：good, moderate, poor
     */
    detectNetworkQuality() {
        // 模拟网络质量检测
        // 实际项目中应使用网络延迟、带宽等数据进行检测
        const qualities = ['good', 'moderate', 'poor'];
        const probabilities = [0.7, 0.2, 0.1]; // 良好网络概率最高
        
        let rand = Math.random();
        let cumulativeProbability = 0;
        
        for (let i = 0; i < qualities.length; i++) {
            cumulativeProbability += probabilities[i];
            if (rand <= cumulativeProbability) {
                return qualities[i];
            }
        }
        
        return 'good';
    }
}

/**
 * 电池状态检测器
 * 检测设备电池状态，用于优化更新频率
 */
class BatteryDetector {
    constructor() {
        this.batteryLevel = 100; // 默认满电
        this.isCharging = false;
        
        // 尝试获取真实电池状态
        this._initializeBatteryMonitoring();
    }
    
    /**
     * 初始化电池监控
     * @private
     */
    _initializeBatteryMonitoring() {
        if (typeof navigator !== 'undefined' && navigator.getBattery) {
            navigator.getBattery().then(battery => {
                this.batteryLevel = battery.level * 100;
                this.isCharging = battery.charging;
                
                // 监听电池状态变化
                battery.addEventListener('levelchange', () => {
                    this.batteryLevel = battery.level * 100;
                });
                
                battery.addEventListener('chargingchange', () => {
                    this.isCharging = battery.charging;
                });
            }).catch(error => {
                console.warn('无法获取电池状态:', error);
            });
        }
    }
    
    /**
     * 获取电池状态
     * @returns {Object} 电池状态对象
     */
    getBatteryState() {
        return {
            level: this.batteryLevel,
            isCharging: this.isCharging,
            status: this._getBatteryStatus()
        };
    }
    
    /**
     * 获取电池状态等级
     * @private
     * @returns {string} 电池状态等级：high, medium, low
     */
    _getBatteryStatus() {
        if (this.batteryLevel > 70) {
            return 'high';
        } else if (this.batteryLevel > 30) {
            return 'medium';
        } else {
            return 'low';
        }
    }
}

/**
 * 位置推送服务
 * 负责将位置信息推送给服务器或其他客户端
 */
class LocationPushService {
    /**
     * 构造函数
     * @param {string} endpoint - 推送服务端点
     */
    constructor(endpoint = 'https://api.example.com/location') {
        this.endpoint = endpoint;
        this.retryCount = 3;
        this.retryDelay = 1000;
    }
    
    /**
     * 推送位置信息
     * @param {Object} location - 位置信息
     * @returns {Promise<boolean>} 是否推送成功
     */
    async pushLocation(location) {
        for (let i = 0; i < this.retryCount; i++) {
            try {
                // 模拟推送位置信息
                // 实际项目中应使用fetch或axios等发送HTTP请求
                console.log(`推送位置信息: ${location.latitude}, ${location.longitude} (尝试${i+1}/${this.retryCount})`);
                
                // 模拟网络延迟
                await new Promise(resolve => setTimeout(resolve, 100));
                
                // 模拟推送成功
                console.log('位置信息推送成功');
                return true;
            } catch (error) {
                console.error(`位置信息推送失败 (${i+1}/${this.retryCount}):`, error);
                
                if (i < this.retryCount - 1) {
                    // 等待一段时间后重试
                    await new Promise(resolve => setTimeout(resolve, this.retryDelay * Math.pow(2, i)));
                }
            }
        }
        
        console.error('位置信息推送失败，已达到最大重试次数');
        return false;
    }
}

/**
 * 位置拉取服务
 * 负责从服务器拉取最新的位置信息
 */
class LocationPullService {
    /**
     * 构造函数
     * @param {string} endpoint - 拉取服务端点
     */
    constructor(endpoint = 'https://api.example.com/location') {
        this.endpoint = endpoint;
        this.retryCount = 3;
        this.retryDelay = 1000;
    }
    
    /**
     * 拉取位置信息
     * @param {string} resourceId - 资源ID
     * @returns {Promise<Object|null>} 位置信息，失败返回null
     */
    async pullLocation(resourceId) {
        for (let i = 0; i < this.retryCount; i++) {
            try {
                // 模拟拉取位置信息
                // 实际项目中应使用fetch或axios等发送HTTP请求
                console.log(`拉取位置信息: 资源${resourceId} (尝试${i+1}/${this.retryCount})`);
                
                // 模拟网络延迟
                await new Promise(resolve => setTimeout(resolve, 100));
                
                // 模拟拉取成功
                const location = {
                    latitude: 39.9042 + (Math.random() - 0.5) * 0.01,
                    longitude: 116.4074 + (Math.random() - 0.5) * 0.01,
                    accuracy: Math.random() * 20 + 5,
                    timestamp: Date.now(),
                    resourceId: resourceId
                };
                
                console.log('位置信息拉取成功:', location);
                return location;
            } catch (error) {
                console.error(`位置信息拉取失败 (${i+1}/${this.retryCount}):`, error);
                
                if (i < this.retryCount - 1) {
                    // 等待一段时间后重试
                    await new Promise(resolve => setTimeout(resolve, this.retryDelay * Math.pow(2, i)));
                }
            }
        }
        
        console.error('位置信息拉取失败，已达到最大重试次数');
        return null;
    }
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        RealTimeUpdateManager,
        ActivityDetector,
        NetworkDetector,
        BatteryDetector,
        LocationPushService,
        LocationPullService
    };
} else if (typeof window !== 'undefined') {
    window.RealTimeUpdateManager = RealTimeUpdateManager;
    window.ActivityDetector = ActivityDetector;
    window.NetworkDetector = NetworkDetector;
    window.BatteryDetector = BatteryDetector;
    window.LocationPushService = LocationPushService;
    window.LocationPullService = LocationPullService;
}
