/**
 * 路径信息与用户位置集成模块
 * 实现路径信息与用户实时位置的深度集成，确保路径计算的准确性
 */

class PathLocationIntegration {
    /**
     * 构造函数
     * @param {Object} options - 配置选项
     * @param {PathPlanningService} options.pathService - 路径规划服务实例
     * @param {Function} options.locationProvider - 位置提供者函数，返回Promise<Object>定位数据
     * @param {number} options.pathUpdateThreshold - 路径更新阈值（米）
     * @param {Function} options.onPathUpdated - 路径更新回调函数
     * @param {Function} options.onLocationUpdated - 位置更新回调函数
     */
    constructor(options = {}) {
        // 依赖项
        this.pathService = options.pathService;
        this.locationProvider = options.locationProvider;
        this.onPathUpdated = options.onPathUpdated;
        this.onLocationUpdated = options.onLocationUpdated;
        
        // 配置选项
        this.pathUpdateThreshold = options.pathUpdateThreshold || 50; // 位置变化超过50米时更新路径
        
        // 状态管理
        this.isRunning = false;
        this.realTimeUpdateManager = null;
        this.currentPath = null;
        this.currentDestination = null;
        this.currentMode = 'walking';
        this.currentOptions = {};
        this.lastPathCalculationTime = 0;
        this.pathCalculationInterval = 30000; // 路径计算最小时间间隔（30秒）
    }

    /**
     * 初始化
     * @returns {void}
     */
    initialize() {
        // 创建实时更新管理器
        this.realTimeUpdateManager = new RealTimeUpdateManager({
            defaultUpdateInterval: 10000,
            minUpdateInterval: 2000,
            maxUpdateInterval: 60000,
            movementThreshold: 10,
            locationProvider: this.locationProvider,
            updateCallback: this._handleLocationUpdate.bind(this)
        });
        
        console.log('路径位置集成模块初始化完成');
    }

    /**
     * 开始路径跟踪
     * @param {Object} destination - 目的地坐标 {lng, lat}
     * @param {string} mode - 交通方式：walking, driving, transit
     * @param {Object} options - 路径规划选项
     * @returns {Promise<Object>} 初始路径规划结果
     */
    async startPathTracking(destination, mode = 'walking', options = {}) {
        if (!this.realTimeUpdateManager) {
            this.initialize();
        }
        
        this.currentDestination = destination;
        this.currentMode = mode;
        this.currentOptions = options;
        
        // 计算初始路径
        const initialPath = await this._calculatePath();
        
        // 开始实时位置更新
        await this.realTimeUpdateManager.start();
        this.isRunning = true;
        
        console.log('路径跟踪已开始');
        return initialPath;
    }

    /**
     * 停止路径跟踪
     * @returns {void}
     */
    stopPathTracking() {
        if (this.realTimeUpdateManager && this.isRunning) {
            this.realTimeUpdateManager.stop();
            this.isRunning = false;
            console.log('路径跟踪已停止');
        }
        
        // 重置状态
        this.currentDestination = null;
        this.currentPath = null;
        this.lastPathCalculationTime = 0;
    }

    /**
     * 手动更新路径
     * @returns {Promise<Object>} 更新后的路径规划结果
     */
    async manualUpdatePath() {
        if (!this.currentDestination) {
            throw new Error('未设置目的地');
        }
        
        return this._calculatePath();
    }

    /**
     * 处理位置更新
     * @param {Object} location - 最新的位置数据
     * @private
     */
    async _handleLocationUpdate(location) {
        // 调用位置更新回调
        if (this.onLocationUpdated) {
            this.onLocationUpdated(location);
        }
        
        // 检查是否需要更新路径
        if (this.currentDestination && this._shouldUpdatePath(location)) {
            await this._calculatePath(location);
        }
    }

    /**
     * 检查是否应该更新路径
     * @param {Object} newLocation - 新的位置数据
     * @returns {boolean} 是否应该更新路径
     * @private
     */
    _shouldUpdatePath(newLocation) {
        // 检查时间间隔
        const timeElapsed = Date.now() - this.lastPathCalculationTime;
        if (timeElapsed < this.pathCalculationInterval) {
            return false;
        }
        
        // 检查路径是否存在
        if (!this.currentPath) {
            return true;
        }
        
        // 检查位置变化
        if (newLocation && newLocation.latitude && newLocation.longitude) {
            const distance = this._calculateDistance(
                newLocation.latitude, newLocation.longitude,
                this.currentPath.origin.lat, this.currentPath.origin.lng
            );
            
            return distance >= this.pathUpdateThreshold;
        }
        
        return false;
    }

    /**
     * 计算路径
     * @param {Object} location - 当前位置数据
     * @returns {Promise<Object>} 路径规划结果
     * @private
     */
    async _calculatePath(location = null) {
        try {
            // 获取最新位置
            const currentLocation = location || await this.locationProvider();
            
            if (!currentLocation || !currentLocation.latitude || !currentLocation.longitude) {
                console.error('无法获取有效的位置数据');
                return null;
            }
            
            // 构建起点坐标
            const origin = {
                lng: currentLocation.longitude,
                lat: currentLocation.latitude
            };
            
            // 计算路径
            const pathResult = await this.pathService.calculatePath(
                origin,
                this.currentDestination,
                this.currentMode,
                this.currentOptions
            );
            
            // 更新路径信息
            this.currentPath = {
                origin: origin,
                destination: this.currentDestination,
                ...pathResult
            };
            
            // 更新最后计算时间
            this.lastPathCalculationTime = Date.now();
            
            // 调用路径更新回调
            if (this.onPathUpdated) {
                this.onPathUpdated(this.currentPath);
            }
            
            console.log('路径更新成功:', {
                origin: origin,
                destination: this.currentDestination,
                mode: this.currentMode,
                distance: pathResult.paths[0]?.distance || 0,
                duration: pathResult.paths[0]?.duration || 0
            });
            
            return pathResult;
        } catch (error) {
            console.error('路径计算失败:', error);
            return null;
        }
    }

    /**
     * 计算两个坐标点之间的距离（米）
     * @param {number} lat1 - 第一个点的纬度
     * @param {number} lon1 - 第一个点的经度
     * @param {number} lat2 - 第二个点的纬度
     * @param {number} lon2 - 第二个点的经度
     * @returns {number} 距离（米）
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

    /**
     * 获取当前状态
     * @returns {Object} 当前状态
     */
    getCurrentState() {
        return {
            isRunning: this.isRunning,
            currentPath: this.currentPath,
            currentDestination: this.currentDestination,
            currentMode: this.currentMode,
            currentOptions: this.currentOptions,
            pathUpdateThreshold: this.pathUpdateThreshold,
            lastPathCalculationTime: this.lastPathCalculationTime,
            realTimeUpdateState: this.realTimeUpdateManager ? this.realTimeUpdateManager.getCurrentState() : null
        };
    }

    /**
     * 更新路径规划选项
     * @param {Object} options - 新的路径规划选项
     * @returns {void}
     */
    updatePathOptions(options) {
        this.currentOptions = { ...this.currentOptions, ...options };
    }

    /**
     * 更新交通方式
     * @param {string} mode - 新的交通方式
     * @returns {Promise<Object>} 更新后的路径规划结果
     */
    async updateTransportMode(mode) {
        this.currentMode = mode;
        return this._calculatePath();
    }

    /**
     * 更新目的地
     * @param {Object} destination - 新的目的地坐标 {lng, lat}
     * @returns {Promise<Object>} 更新后的路径规划结果
     */
    async updateDestination(destination) {
        this.currentDestination = destination;
        return this._calculatePath();
    }
}

/**
 * 创建路径位置集成实例
 * @param {Object} options - 配置选项
 * @returns {PathLocationIntegration} 路径位置集成实例
 */
function createPathLocationIntegration(options) {
    return new PathLocationIntegration(options);
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        PathLocationIntegration,
        createPathLocationIntegration
    };
} else if (typeof window !== 'undefined') {
    window.PathLocationIntegration = PathLocationIntegration;
    window.createPathLocationIntegration = createPathLocationIntegration;
}
