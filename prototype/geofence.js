/**
 * 地理围栏模块
 * 实现地理围栏的创建、管理、检测和基于地理围栏的资源筛选
 */

/**
 * 地理围栏类
 * 表示一个地理围栏，包含围栏的属性和方法
 */
class Geofence {
    /**
     * 构造函数
     * @param {Object} options - 地理围栏选项
     * @param {string} options.id - 地理围栏ID
     * @param {string} options.name - 地理围栏名称
     * @param {string} options.type - 地理围栏类型：circle, polygon, rectangle
     * @param {Array} options.coordinates - 地理围栏坐标
     * @param {number} options.radius - 圆形围栏半径（米）
     * @param {Object} options.metadata - 地理围栏元数据
     */
    constructor(options = {}) {
        this.id = options.id || `geofence_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
        this.name = options.name || '未命名地理围栏';
        this.type = options.type || 'circle'; // circle, polygon, rectangle
        this.coordinates = options.coordinates || [];
        this.radius = options.radius || 100; // 默认半径100米
        this.metadata = options.metadata || {};
        this.createdAt = options.createdAt || Date.now();
        this.updatedAt = Date.now();
    }
    
    /**
     * 获取地理围栏中心点
     * @returns {Object|null} 中心点坐标 {latitude, longitude}
     */
    getCenter() {
        if (this.type === 'circle') {
            if (this.coordinates.length >= 2) {
                return {
                    latitude: this.coordinates[0],
                    longitude: this.coordinates[1]
                };
            }
        } else if (this.type === 'polygon' || this.type === 'rectangle') {
            if (this.coordinates.length >= 3) {
                let latSum = 0;
                let lonSum = 0;
                const count = this.coordinates.length;
                
                for (const coord of this.coordinates) {
                    latSum += coord[0];
                    lonSum += coord[1];
                }
                
                return {
                    latitude: latSum / count,
                    longitude: lonSum / count
                };
            }
        }
        
        return null;
    }
    
    /**
     * 计算地理围栏面积
     * @returns {number} 面积（平方米）
     */
    getArea() {
        if (this.type === 'circle') {
            return Math.PI * Math.pow(this.radius, 2);
        } else if (this.type === 'polygon') {
            return this._calculatePolygonArea(this.coordinates);
        } else if (this.type === 'rectangle') {
            if (this.coordinates.length >= 4) {
                const width = this._calculateDistance(
                    this.coordinates[0][0], this.coordinates[0][1],
                    this.coordinates[1][0], this.coordinates[1][1]
                );
                const height = this._calculateDistance(
                    this.coordinates[0][0], this.coordinates[0][1],
                    this.coordinates[3][0], this.coordinates[3][1]
                );
                return width * height;
            }
        }
        
        return 0;
    }
    
    /**
     * 检查点是否在地理围栏内
     * @param {number} latitude - 纬度
     * @param {number} longitude - 经度
     * @returns {boolean} 是否在地理围栏内
     */
    containsPoint(latitude, longitude) {
        if (this.type === 'circle') {
            return this._isPointInCircle(latitude, longitude);
        } else if (this.type === 'polygon') {
            return this._isPointInPolygon(latitude, longitude);
        } else if (this.type === 'rectangle') {
            return this._isPointInRectangle(latitude, longitude);
        }
        
        return false;
    }
    
    /**
     * 更新地理围栏属性
     * @param {Object} updates - 更新的属性
     */
    update(updates) {
        Object.assign(this, updates);
        this.updatedAt = Date.now();
    }
    
    /**
     * 转换为JSON对象
     * @returns {Object} JSON对象
     */
    toJSON() {
        return {
            id: this.id,
            name: this.name,
            type: this.type,
            coordinates: this.coordinates,
            radius: this.radius,
            metadata: this.metadata,
            createdAt: this.createdAt,
            updatedAt: this.updatedAt
        };
    }
    
    /**
     * 从JSON对象创建地理围栏
     * @static
     * @param {Object} json - JSON对象
     * @returns {Geofence} 地理围栏实例
     */
    static fromJSON(json) {
        return new Geofence(json);
    }
    
    /**
     * 计算多边形面积
     * @private
     * @param {Array} coordinates - 多边形坐标
     * @returns {number} 面积（平方米）
     */
    _calculatePolygonArea(coordinates) {
        // 使用Shoelace公式计算多边形面积
        let area = 0;
        const n = coordinates.length;
        
        for (let i = 0; i < n; i++) {
            const j = (i + 1) % n;
            const xi = coordinates[i][0];
            const yi = coordinates[i][1];
            const xj = coordinates[j][0];
            const yj = coordinates[j][1];
            area += (xi * yj) - (xj * yi);
        }
        
        area = Math.abs(area) / 2;
        
        // 转换为平方米（基于地球半径）
        const R = 6371000; // 地球半径（米）
        const conversionFactor = (Math.PI * R * R) / (180 * 180);
        return area * conversionFactor;
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
     * 检查点是否在圆形围栏内
     * @private
     * @param {number} latitude - 纬度
     * @param {number} longitude - 经度
     * @returns {boolean} 是否在圆形围栏内
     */
    _isPointInCircle(latitude, longitude) {
        if (this.coordinates.length < 2) {
            return false;
        }
        
        const distance = this._calculateDistance(
            this.coordinates[0], this.coordinates[1],
            latitude, longitude
        );
        
        return distance <= this.radius;
    }
    
    /**
     * 检查点是否在多边形围栏内
     * @private
     * @param {number} latitude - 纬度
     * @param {number} longitude - 经度
     * @returns {boolean} 是否在多边形围栏内
     */
    _isPointInPolygon(latitude, longitude) {
        if (this.coordinates.length < 3) {
            return false;
        }
        
        let inside = false;
        const n = this.coordinates.length;
        
        for (let i = 0, j = n - 1; i < n; j = i++) {
            const xi = this.coordinates[i][0];
            const yi = this.coordinates[i][1];
            const xj = this.coordinates[j][0];
            const yj = this.coordinates[j][1];
            
            const intersect = ((yi > longitude) !== (yj > longitude)) &&
                (latitude < (xj - xi) * (longitude - yi) / (yj - yi) + xi);
            
            if (intersect) {
                inside = !inside;
            }
        }
        
        return inside;
    }
    
    /**
     * 检查点是否在矩形围栏内
     * @private
     * @param {number} latitude - 纬度
     * @param {number} longitude - 经度
     * @returns {boolean} 是否在矩形围栏内
     */
    _isPointInRectangle(latitude, longitude) {
        if (this.coordinates.length < 4) {
            return false;
        }
        
        // 找到矩形的边界
        const lats = this.coordinates.map(coord => coord[0]);
        const lons = this.coordinates.map(coord => coord[1]);
        
        const minLat = Math.min(...lats);
        const maxLat = Math.max(...lats);
        const minLon = Math.min(...lons);
        const maxLon = Math.max(...lons);
        
        return latitude >= minLat && latitude <= maxLat &&
               longitude >= minLon && longitude <= maxLon;
    }
}

/**
 * 地理围栏管理器
 * 管理多个地理围栏的创建、存储、加载和删除
 */
class GeofenceManager {
    /**
     * 构造函数
     * @param {Object} options - 地理围栏管理器选项
     * @param {GeofenceStorage} options.storage - 地理围栏存储
     */
    constructor(options = {}) {
        this.geofences = new Map();
        this.storage = options.storage || new GeofenceStorage();
        this.eventListeners = new Map();
    }
    
    /**
     * 初始化地理围栏管理器
     * @returns {Promise<void>}
     */
    async initialize() {
        try {
            const geofences = await this.storage.loadAll();
            geofences.forEach(geofence => {
                this.geofences.set(geofence.id, geofence);
            });
            console.log(`地理围栏管理器初始化成功，加载了 ${geofences.length} 个地理围栏`);
        } catch (error) {
            console.error('地理围栏管理器初始化失败:', error);
        }
    }
    
    /**
     * 创建地理围栏
     * @param {Object} options - 地理围栏选项
     * @returns {Geofence} 创建的地理围栏
     */
    createGeofence(options) {
        const geofence = new Geofence(options);
        this.geofences.set(geofence.id, geofence);
        this._saveGeofence(geofence);
        this._emit('created', geofence);
        return geofence;
    }
    
    /**
     * 获取地理围栏
     * @param {string} id - 地理围栏ID
     * @returns {Geofence|null} 地理围栏
     */
    getGeofence(id) {
        return this.geofences.get(id) || null;
    }
    
    /**
     * 获取所有地理围栏
     * @returns {Array<Geofence>} 地理围栏列表
     */
    getAllGeofences() {
        return Array.from(this.geofences.values());
    }
    
    /**
     * 更新地理围栏
     * @param {string} id - 地理围栏ID
     * @param {Object} updates - 更新的属性
     * @returns {Geofence|null} 更新后的地理围栏
     */
    updateGeofence(id, updates) {
        const geofence = this.geofences.get(id);
        if (geofence) {
            geofence.update(updates);
            this._saveGeofence(geofence);
            this._emit('updated', geofence);
            return geofence;
        }
        return null;
    }
    
    /**
     * 删除地理围栏
     * @param {string} id - 地理围栏ID
     * @returns {boolean} 是否删除成功
     */
    deleteGeofence(id) {
        if (this.geofences.has(id)) {
            this.geofences.delete(id);
            this._removeGeofence(id);
            this._emit('deleted', id);
            return true;
        }
        return false;
    }
    
    /**
     * 清除所有地理围栏
     * @returns {Promise<void>}
     */
    async clearAllGeofences() {
        this.geofences.clear();
        await this.storage.clear();
        this._emit('cleared');
    }
    
    /**
     * 保存地理围栏到存储
     * @private
     * @param {Geofence} geofence - 地理围栏
     */
    async _saveGeofence(geofence) {
        try {
            await this.storage.save(geofence);
        } catch (error) {
            console.error('保存地理围栏失败:', error);
        }
    }
    
    /**
     * 从存储中删除地理围栏
     * @private
     * @param {string} id - 地理围栏ID
     */
    async _removeGeofence(id) {
        try {
            await this.storage.remove(id);
        } catch (error) {
            console.error('删除地理围栏失败:', error);
        }
    }
    
    /**
     * 添加事件监听器
     * @param {string} event - 事件名称
     * @param {Function} listener - 事件监听器
     */
    on(event, listener) {
        if (!this.eventListeners.has(event)) {
            this.eventListeners.set(event, []);
        }
        this.eventListeners.get(event).push(listener);
    }
    
    /**
     * 移除事件监听器
     * @param {string} event - 事件名称
     * @param {Function} listener - 事件监听器
     */
    off(event, listener) {
        if (this.eventListeners.has(event)) {
            const listeners = this.eventListeners.get(event);
            const index = listeners.indexOf(listener);
            if (index > -1) {
                listeners.splice(index, 1);
            }
        }
    }
    
    /**
     * 触发事件
     * @private
     * @param {string} event - 事件名称
     * @param {*} data - 事件数据
     */
    _emit(event, data) {
        if (this.eventListeners.has(event)) {
            const listeners = this.eventListeners.get(event);
            listeners.forEach(listener => {
                try {
                    listener(data);
                } catch (error) {
                    console.error('事件监听器执行失败:', error);
                }
            });
        }
    }
}

/**
 * 地理围栏存储
 * 负责地理围栏数据的持久化存储
 */
class GeofenceStorage {
    /**
     * 构造函数
     * @param {Object} options - 存储选项
     * @param {string} options.storageKey - 存储键名
     */
    constructor(options = {}) {
        this.storageKey = options.storageKey || 'geofences';
    }
    
    /**
     * 保存地理围栏
     * @param {Geofence} geofence - 地理围栏
     * @returns {Promise<void>}
     */
    async save(geofence) {
        try {
            const geofences = await this.loadAll();
            const index = geofences.findIndex(g => g.id === geofence.id);
            
            if (index > -1) {
                geofences[index] = geofence.toJSON();
            } else {
                geofences.push(geofence.toJSON());
            }
            
            localStorage.setItem(this.storageKey, JSON.stringify(geofences));
        } catch (error) {
            console.error('保存地理围栏失败:', error);
            throw error;
        }
    }
    
    /**
     * 加载所有地理围栏
     * @returns {Promise<Array<Geofence>>}
     */
    async loadAll() {
        try {
            const data = localStorage.getItem(this.storageKey);
            if (!data) {
                return [];
            }
            
            const geofences = JSON.parse(data);
            return geofences.map(geo => Geofence.fromJSON(geo));
        } catch (error) {
            console.error('加载地理围栏失败:', error);
            return [];
        }
    }
    
    /**
     * 从存储中删除地理围栏
     * @param {string} id - 地理围栏ID
     * @returns {Promise<void>}
     */
    async remove(id) {
        try {
            const geofences = await this.loadAll();
            const filteredGeofences = geofences.filter(g => g.id !== id);
            localStorage.setItem(this.storageKey, JSON.stringify(filteredGeofences));
        } catch (error) {
            console.error('删除地理围栏失败:', error);
            throw error;
        }
    }
    
    /**
     * 清空所有地理围栏
     * @returns {Promise<void>}
     */
    async clear() {
        try {
            localStorage.removeItem(this.storageKey);
        } catch (error) {
            console.error('清空地理围栏失败:', error);
            throw error;
        }
    }
}

/**
 * 地理围栏检测器
 * 检测位置是否在地理围栏内
 */
class GeofenceDetector {
    /**
     * 构造函数
     * @param {GeofenceManager} geofenceManager - 地理围栏管理器
     */
    constructor(geofenceManager) {
        this.geofenceManager = geofenceManager;
        this.lastDetectionResults = new Map();
    }
    
    /**
     * 检测位置是否在任何地理围栏内
     * @param {number} latitude - 纬度
     * @param {number} longitude - 经度
     * @returns {Array<Geofence>} 包含该位置的地理围栏列表
     */
    detect(latitude, longitude) {
        const containingGeofences = [];
        const geofences = this.geofenceManager.getAllGeofences();
        
        geofences.forEach(geofence => {
            if (geofence.containsPoint(latitude, longitude)) {
                containingGeofences.push(geofence);
            }
        });
        
        // 保存检测结果
        const detectionId = `${latitude}_${longitude}`;
        this.lastDetectionResults.set(detectionId, {
            timestamp: Date.now(),
            geofences: containingGeofences
        });
        
        return containingGeofences;
    }
    
    /**
     * 检测位置是否在指定地理围栏内
     * @param {string} geofenceId - 地理围栏ID
     * @param {number} latitude - 纬度
     * @param {number} longitude - 经度
     * @returns {boolean} 是否在指定地理围栏内
     */
    detectInSpecificGeofence(geofenceId, latitude, longitude) {
        const geofence = this.geofenceManager.getGeofence(geofenceId);
        if (!geofence) {
            return false;
        }
        
        return geofence.containsPoint(latitude, longitude);
    }
    
    /**
     * 获取最后一次检测结果
     * @param {number} latitude - 纬度
     * @param {number} longitude - 经度
     * @returns {Object|null} 最后一次检测结果
     */
    getLastDetectionResult(latitude, longitude) {
        const detectionId = `${latitude}_${longitude}`;
        return this.lastDetectionResults.get(detectionId) || null;
    }
    
    /**
     * 清除检测结果缓存
     */
    clearCache() {
        this.lastDetectionResults.clear();
    }
}

/**
 * 地理围栏资源筛选器
 * 基于地理围栏筛选资源
 */
class GeofenceResourceFilter {
    /**
     * 构造函数
     * @param {GeofenceDetector} geofenceDetector - 地理围栏检测器
     */
    constructor(geofenceDetector) {
        this.geofenceDetector = geofenceDetector;
    }
    
    /**
     * 筛选在地理围栏内的资源
     * @param {Array} resources - 资源列表
     * @param {string} geofenceId - 地理围栏ID
     * @returns {Array} 在地理围栏内的资源列表
     */
    filterResourcesByGeofence(resources, geofenceId) {
        if (!resources || !Array.isArray(resources)) {
            return [];
        }
        
        return resources.filter(resource => {
            if (!resource.location || !resource.location.latitude || !resource.location.longitude) {
                return false;
            }
            
            return this.geofenceDetector.detectInSpecificGeofence(
                geofenceId,
                resource.location.latitude,
                resource.location.longitude
            );
        });
    }
    
    /**
     * 筛选在任何地理围栏内的资源
     * @param {Array} resources - 资源列表
     * @returns {Object} 按地理围栏分组的资源
     */
    filterResourcesByAnyGeofence(resources) {
        if (!resources || !Array.isArray(resources)) {
            return {};
        }
        
        const result = {};
        
        resources.forEach(resource => {
            if (!resource.location || !resource.location.latitude || !resource.location.longitude) {
                return;
            }
            
            const containingGeofences = this.geofenceDetector.detect(
                resource.location.latitude,
                resource.location.longitude
            );
            
            containingGeofences.forEach(geofence => {
                if (!result[geofence.id]) {
                    result[geofence.id] = {
                        geofence: geofence,
                        resources: []
                    };
                }
                result[geofence.id].resources.push(resource);
            });
        });
        
        return result;
    }
    
    /**
     * 计算资源到地理围栏的距离
     * @param {Object} resource - 资源
     * @param {string} geofenceId - 地理围栏ID
     * @returns {number|null} 距离（米），如果资源没有位置信息则返回null
     */
    calculateDistanceToGeofence(resource, geofenceId) {
        if (!resource.location || !resource.location.latitude || !resource.location.longitude) {
            return null;
        }
        
        const geofence = this.geofenceDetector.geofenceManager.getGeofence(geofenceId);
        if (!geofence) {
            return null;
        }
        
        if (geofence.type === 'circle') {
            const center = geofence.getCenter();
            if (center) {
                const R = 6371000; // 地球半径（米）
                const φ1 = (center.latitude * Math.PI) / 180;
                const φ2 = (resource.location.latitude * Math.PI) / 180;
                const Δφ = ((resource.location.latitude - center.latitude) * Math.PI) / 180;
                const Δλ = ((resource.location.longitude - center.longitude) * Math.PI) / 180;
                
                const a = Math.sin(Δφ / 2) * Math.sin(Δφ / 2) +
                          Math.cos(φ1) * Math.cos(φ2) *
                          Math.sin(Δλ / 2) * Math.sin(Δλ / 2);
                const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
                
                const distance = R * c;
                return distance - geofence.radius;
            }
        }
        
        return null;
    }
}

/**
 * 地理围栏模块导出
 */
const geofenceModule = {
    Geofence,
    GeofenceManager,
    GeofenceStorage,
    GeofenceDetector,
    GeofenceResourceFilter
};

// 全局变量，方便其他脚本使用
if (typeof window !== 'undefined') {
    window.geofenceModule = geofenceModule;
    
    // 创建默认的地理围栏管理器实例
    const geofenceManager = new GeofenceManager();
    window.geofenceManager = geofenceManager;
    
    // 创建默认的地理围栏检测器实例
    const geofenceDetector = new GeofenceDetector(geofenceManager);
    window.geofenceDetector = geofenceDetector;
    
    // 创建默认的地理围栏资源筛选器实例
    const geofenceResourceFilter = new GeofenceResourceFilter(geofenceDetector);
    window.geofenceResourceFilter = geofenceResourceFilter;
    
    // 初始化地理围栏管理器
    geofenceManager.initialize().catch(error => {
        console.error('地理围栏管理器初始化失败:', error);
    });
}

// 模块导出
if (typeof module !== 'undefined' && module.exports) {
    module.exports = geofenceModule;
}
