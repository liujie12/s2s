/**
 * 智能权限管理模块
 * 根据不同场景智能申请定位权限，提升用户体验
 */

/**
 * 权限管理服务
 */
class PermissionManager {
    constructor() {
        // 权限状态缓存
        this.permissionCache = {
            geolocation: null,
            lastChecked: null
        };
        
        // 权限申请历史
        this.requestHistory = [];
        
        // 场景定义
        this.scenarios = {
            SEARCH: 'search',
            PUBLISH: 'publish',
            MAP: 'map',
            NEARBY: 'nearby'
        };
        
        // 场景权限需求级别
        this.scenarioLevels = {
            search: {
                level: 1,
                description: '为了提供附近的资源/需求推荐'
            },
            publish: {
                level: 2,
                description: '为了自动填充发布地点信息'
            },
            map: {
                level: 3,
                description: '为了在地图上显示资源/需求位置'
            },
            nearby: {
                level: 3,
                description: '为了提供精准的附近资源/需求'
            }
        };
        
        // 权限状态
        this.permissionStatus = {
            GRANTED: 'granted',
            DENIED: 'denied',
            PROMPT: 'prompt'
        };
    }

    /**
     * 获取当前定位权限状态
     * @returns {Promise<string>} 权限状态
     */
    async getGeolocationPermission() {
        // 检查缓存
        if (this.permissionCache.geolocation && 
            (Date.now() - this.permissionCache.lastChecked < 300000)) { // 5分钟缓存
            return this.permissionCache.geolocation;
        }

        if (typeof navigator !== 'undefined' && navigator.permissions) {
            try {
                const permission = await navigator.permissions.query({ name: 'geolocation' });
                const status = permission.state;
                
                // 更新缓存
                this.permissionCache.geolocation = status;
                this.permissionCache.lastChecked = Date.now();
                
                return status;
            } catch (error) {
                console.warn('获取权限状态失败:', error);
                return this.permissionStatus.PROMPT;
            }
        } else {
            // 浏览器不支持Permissions API，使用Geolocation API测试
            return new Promise((resolve) => {
                if (typeof navigator !== 'undefined' && navigator.geolocation) {
                    navigator.geolocation.getCurrentPosition(
                        () => {
                            this.permissionCache.geolocation = this.permissionStatus.GRANTED;
                            this.permissionCache.lastChecked = Date.now();
                            resolve(this.permissionStatus.GRANTED);
                        },
                        (error) => {
                            if (error.code === error.PERMISSION_DENIED) {
                                this.permissionCache.geolocation = this.permissionStatus.DENIED;
                            } else {
                                this.permissionCache.geolocation = this.permissionStatus.PROMPT;
                            }
                            this.permissionCache.lastChecked = Date.now();
                            resolve(this.permissionCache.geolocation);
                        },
                        { timeout: 1000 }
                    );
                } else {
                    resolve(this.permissionStatus.DENIED);
                }
            });
        }
    }

    /**
     * 智能申请定位权限
     * @param {string} scenario - 使用场景
     * @returns {Promise<boolean>} 是否获得权限
     */
    async requestGeolocationPermission(scenario) {
        const currentStatus = await this.getGeolocationPermission();
        
        // 如果已经授予权限，直接返回
        if (currentStatus === this.permissionStatus.GRANTED) {
            this._logRequest(scenario, 'granted', 'already granted');
            return true;
        }
        
        // 如果已经拒绝权限，不再请求
        if (currentStatus === this.permissionStatus.DENIED) {
            this._logRequest(scenario, 'denied', 'previously denied');
            return false;
        }
        
        // 检查是否在短时间内重复请求
        if (this._isRecentRequest(scenario)) {
            this._logRequest(scenario, 'denied', 'recent request');
            return false;
        }
        
        // 获取场景信息
        const scenarioInfo = this.scenarioLevels[scenario] || { level: 1, description: '为了提供更好的服务' };
        
        // 显示权限申请说明
        const userConfirmed = await this._showPermissionExplanation(scenario, scenarioInfo.description);
        
        if (!userConfirmed) {
            this._logRequest(scenario, 'denied', 'user cancelled');
            return false;
        }
        
        // 实际申请权限
        return new Promise((resolve) => {
            if (typeof navigator !== 'undefined' && navigator.geolocation) {
                navigator.geolocation.getCurrentPosition(
                    () => {
                        this.permissionCache.geolocation = this.permissionStatus.GRANTED;
                        this.permissionCache.lastChecked = Date.now();
                        this._logRequest(scenario, 'granted', 'user approved');
                        resolve(true);
                    },
                    (error) => {
                        if (error.code === error.PERMISSION_DENIED) {
                            this.permissionCache.geolocation = this.permissionStatus.DENIED;
                        }
                        this.permissionCache.lastChecked = Date.now();
                        this._logRequest(scenario, 'denied', 'user rejected');
                        resolve(false);
                    },
                    {
                        enableHighAccuracy: false,
                        timeout: 5000,
                        maximumAge: 0
                    }
                );
            } else {
                resolve(false);
            }
        });
    }

    /**
     * 显示权限申请说明
     * @param {string} scenario - 使用场景
     * @param {string} description - 权限使用说明
     * @returns {Promise<boolean>} 用户是否确认
     * @private
     */
    _showPermissionExplanation(scenario, description) {
        return new Promise((resolve) => {
            // 在实际应用中，这里应该显示一个美观的模态框
            // 这里使用confirm作为示例
            const message = `我们需要获取您的位置信息，${description}。\n\n这将帮助我们为您提供更精准的服务和推荐。`;
            
            if (typeof window !== 'undefined' && window.confirm) {
                const confirmed = window.confirm(message);
                resolve(confirmed);
            } else {
                // 非浏览器环境，默认同意
                resolve(true);
            }
        });
    }

    /**
     * 检查是否在短时间内重复请求
     * @param {string} scenario - 使用场景
     * @returns {boolean} 是否在短时间内重复请求
     * @private
     */
    _isRecentRequest(scenario) {
        const now = Date.now();
        const recentRequests = this.requestHistory.filter(item => 
            item.scenario === scenario && (now - item.timestamp < 60000) // 1分钟内
        );
        
        return recentRequests.length > 0;
    }

    /**
     * 记录权限请求
     * @param {string} scenario - 使用场景
     * @param {string} result - 请求结果
     * @param {string} reason - 原因
     * @private
     */
    _logRequest(scenario, result, reason) {
        this.requestHistory.push({
            scenario,
            result,
            reason,
            timestamp: Date.now()
        });
        
        // 限制历史记录长度
        if (this.requestHistory.length > 50) {
            this.requestHistory.shift();
        }
        
        console.log(`权限请求: ${scenario} - ${result} (${reason})`);
    }

    /**
     * 获取权限申请策略
     * @param {string} scenario - 使用场景
     * @returns {Object} 权限申请策略
     */
    getPermissionStrategy(scenario) {
        return this.scenarioLevels[scenario] || {
            level: 1,
            description: '为了提供更好的服务'
        };
    }

    /**
     * 获取降级方案
     * @param {string} scenario - 使用场景
     * @returns {Object} 降级方案
     */
    getFallbackStrategy(scenario) {
        const strategies = {
            search: {
                message: '您可以手动输入位置信息，或浏览全部资源/需求',
                actions: [
                    { label: '手动输入位置', action: 'manual_location' },
                    { label: '浏览全部', action: 'browse_all' }
                ]
            },
            publish: {
                message: '您可以手动输入发布地点信息',
                actions: [
                    { label: '手动输入地点', action: 'manual_location' }
                ]
            },
            map: {
                message: '地图功能需要定位权限，您可以使用列表模式查看资源/需求',
                actions: [
                    { label: '切换到列表模式', action: 'switch_to_list' }
                ]
            },
            nearby: {
                message: '附近功能需要定位权限，您可以手动输入位置或浏览全部资源/需求',
                actions: [
                    { label: '手动输入位置', action: 'manual_location' },
                    { label: '浏览全部', action: 'browse_all' }
                ]
            }
        };
        
        return strategies[scenario] || {
            message: '您可以手动输入位置信息或浏览全部资源/需求',
            actions: [
                { label: '手动输入位置', action: 'manual_location' },
                { label: '浏览全部', action: 'browse_all' }
            ]
        };
    }

    /**
     * 显示权限被拒绝的降级方案
     * @param {string} scenario - 使用场景
     * @returns {Promise<string>} 用户选择的操作
     */
    async showFallbackOptions(scenario) {
        const fallback = this.getFallbackStrategy(scenario);
        
        return new Promise((resolve) => {
            // 在实际应用中，这里应该显示一个美观的模态框
            // 这里使用prompt作为示例
            let optionsText = fallback.actions.map((action, index) => 
                `${index + 1}. ${action.label}`
            ).join('\n');
            
            const message = `${fallback.message}\n\n请选择一个选项:\n${optionsText}`;
            
            if (typeof window !== 'undefined' && window.prompt) {
                const userInput = window.prompt(message, '1');
                const selectedIndex = parseInt(userInput) - 1;
                
                if (selectedIndex >= 0 && selectedIndex < fallback.actions.length) {
                    resolve(fallback.actions[selectedIndex].action);
                } else {
                    resolve(fallback.actions[0].action);
                }
            } else {
                // 非浏览器环境，返回第一个选项
                resolve(fallback.actions[0].action);
            }
        });
    }

    /**
     * 清除权限缓存
     */
    clearCache() {
        this.permissionCache = {
            geolocation: null,
            lastChecked: null
        };
    }

    /**
     * 获取权限申请历史
     * @returns {Array} 权限申请历史
     */
    getRequestHistory() {
        return [...this.requestHistory];
    }

    /**
     * 智能判断是否需要申请权限
     * @param {string} scenario - 使用场景
     * @returns {Promise<boolean>} 是否需要申请权限
     */
    async shouldRequestPermission(scenario) {
        const status = await this.getGeolocationPermission();
        
        // 如果已经授予权限，不需要申请
        if (status === this.permissionStatus.GRANTED) {
            return false;
        }
        
        // 如果已经拒绝权限，不需要申请
        if (status === this.permissionStatus.DENIED) {
            return false;
        }
        
        // 检查是否在短时间内重复请求
        if (this._isRecentRequest(scenario)) {
            return false;
        }
        
        return true;
    }
}

// 导出模块
const permissionManager = new PermissionManager();

if (typeof window !== 'undefined') {
    window.permissionManager = permissionManager;
    window.PermissionManager = PermissionManager;
}

if (typeof module !== 'undefined' && module.exports) {
    module.exports = PermissionManager;
    module.exports.permissionManager = permissionManager;
}
