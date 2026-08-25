/**
 * 快速匹配模块
 * 基于距离和分类的初步匹配，响应时间不超过100ms
 */
class FastMatcher {
    /**
     * 构造函数
     * @param {Object} options 配置选项
     */
    constructor(options = {}) {
        this.config = {
            maxDistance: options.maxDistance || 50, // 最大搜索距离（km）
            limit: options.limit || 20, // 返回结果数量
            cacheTTL: options.cacheTTL || 3600, // 缓存过期时间（秒）
            ...options
        };
        this.cache = new Map();
    }

    /**
     * 计算两点之间的距离（使用Haversine公式）
     * @param {Array} coord1 第一个坐标 [lng, lat]
     * @param {Array} coord2 第二个坐标 [lng, lat]
     * @returns {number} 距离（公里）
     */
    calculateDistance(coord1, coord2) {
        if (!coord1 || !coord2) return Infinity;
        
        const R = 6371; // 地球半径（公里）
        const dLat = (coord2[1] - coord1[1]) * Math.PI / 180;
        const dLng = (coord2[0] - coord1[0]) * Math.PI / 180;
        const a = 
            Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(coord1[1] * Math.PI / 180) * Math.cos(coord2[1] * Math.PI / 180) *
            Math.sin(dLng / 2) * Math.sin(dLng / 2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        const distance = R * c;
        return distance;
    }

    /**
     * 基于距离筛选资源
     * @param {Array} resources 资源列表
     * @param {Object} location 用户位置 {lat, lng}
     * @param {number} maxDistance 最大搜索距离（km）
     * @returns {Array} 距离筛选后的资源列表
     */
    filterByDistance(resources, location, maxDistance = this.config.maxDistance) {
        if (!location || !location.lat || !location.lng) return resources;
        
        return resources.filter(resource => {
            if (!resource.coordinates) return false;
            const distance = this.calculateDistance(
                [location.lng, location.lat],
                resource.coordinates
            );
            return distance <= maxDistance;
        });
    }

    /**
     * 基于分类筛选资源
     * @param {Array} resources 资源列表
     * @param {string} category 目标分类
     * @param {Object} categoryTree 分类树结构
     * @returns {Array} 分类筛选后的资源列表
     */
    filterByCategory(resources, category, categoryTree = {}) {
        if (!category || category === 'all') return resources;
        
        return resources.filter(resource => {
            if (!resource.category) return false;
            
            // 完全匹配
            if (resource.category === category) return true;
            
            // 子分类匹配
            for (const parent in categoryTree) {
                if (categoryTree.hasOwnProperty(parent)) {
                    const children = categoryTree[parent];
                    // 检查是否属于同一父分类
                    if (children.includes(resource.category) && children.includes(category)) {
                        return true;
                    }
                    // 检查是否为父子分类关系
                    if (parent === category && children.includes(resource.category)) {
                        return true;
                    }
                    if (parent === resource.category && children.includes(category)) {
                        return true;
                    }
                }
            }
            
            return false;
        });
    }

    /**
     * 基于查询文本筛选资源
     * @param {Array} resources 资源列表
     * @param {string} query 查询文本
     * @returns {Array} 查询文本筛选后的资源列表
     */
    filterByQuery(resources, query) {
        if (!query) return resources;
        
        const queryLower = query.toLowerCase();
        return resources.filter(resource => {
            // 检查标题
            if (resource.title && resource.title.toLowerCase().includes(queryLower)) {
                return true;
            }
            // 检查描述
            if (resource.description && resource.description.toLowerCase().includes(queryLower)) {
                return true;
            }
            // 检查标签
            if (resource.tags && resource.tags.some(tag => tag.toLowerCase().includes(queryLower))) {
                return true;
            }
            // 检查分类
            if (resource.category && resource.category.toLowerCase().includes(queryLower)) {
                return true;
            }
            return false;
        });
    }

    /**
     * 生成缓存键
     * @param {Object} params 查询参数
     * @returns {string} 缓存键
     */
    generateCacheKey(params) {
        const { query, location, category, radius } = params;
        return `${query || ''}_${location?.lat || ''}_${location?.lng || ''}_${category || ''}_${radius || ''}`;
    }

    /**
     * 检查缓存
     * @param {string} cacheKey 缓存键
     * @returns {Object|null} 缓存结果或null
     */
    checkCache(cacheKey) {
        const cached = this.cache.get(cacheKey);
        if (!cached) return null;
        
        const { data, timestamp } = cached;
        const now = Date.now();
        
        // 检查缓存是否过期
        if (now - timestamp > this.config.cacheTTL * 1000) {
            this.cache.delete(cacheKey);
            return null;
        }
        
        return data;
    }

    /**
     * 设置缓存
     * @param {string} cacheKey 缓存键
     * @param {Object} data 要缓存的数据
     */
    setCache(cacheKey, data) {
        this.cache.set(cacheKey, {
            data,
            timestamp: Date.now()
        });
        
        // 限制缓存大小
        if (this.cache.size > 1000) {
            // 移除最早的缓存项
            const firstKey = this.cache.keys().next().value;
            this.cache.delete(firstKey);
        }
    }

    /**
     * 执行快速匹配
     * @param {Array} resources 资源列表
     * @param {Object} params 查询参数
     * @param {Object} options 选项
     * @returns {Object} 快速匹配结果
     */
    match(resources, params, options = {}) {
        const startTime = Date.now();
        
        // 生成缓存键
        const cacheKey = this.generateCacheKey(params);
        
        // 检查缓存
        const cachedResult = this.checkCache(cacheKey);
        if (cachedResult) {
            console.log('快速匹配: 使用缓存结果');
            return {
                ...cachedResult,
                time: Date.now() - startTime,
                cached: true
            };
        }
        
        const { location, category, radius, query } = params;
        const maxDistance = radius || this.config.maxDistance;
        
        // 基于距离筛选
        let filteredResources = this.filterByDistance(resources, location, maxDistance);
        
        // 基于分类筛选
        filteredResources = this.filterByCategory(filteredResources, category);
        
        // 基于查询文本筛选
        filteredResources = this.filterByQuery(filteredResources, query);
        
        // 按距离排序
        if (location && location.lat && location.lng) {
            filteredResources.sort((a, b) => {
                const distanceA = this.calculateDistance(
                    [location.lng, location.lat],
                    a.coordinates
                );
                const distanceB = this.calculateDistance(
                    [location.lng, location.lat],
                    b.coordinates
                );
                return distanceA - distanceB;
            });
        }
        
        // 限制返回数量
        const limitedResources = filteredResources.slice(0, this.config.limit);
        
        // 生成结果
        const result = {
            results: limitedResources,
            total: filteredResources.length,
            time: Date.now() - startTime,
            cached: false
        };
        
        // 设置缓存
        this.setCache(cacheKey, result);
        
        console.log(`快速匹配: 处理了 ${resources.length} 个资源，返回 ${limitedResources.length} 个结果，耗时 ${result.time}ms`);
        
        return result;
    }

    /**
     * 清除缓存
     * @param {string} cacheKey 缓存键（可选，不提供则清除所有缓存）
     */
    clearCache(cacheKey) {
        if (cacheKey) {
            this.cache.delete(cacheKey);
        } else {
            this.cache.clear();
        }
    }

    /**
     * 获取缓存状态
     * @returns {Object} 缓存状态
     */
    getCacheStatus() {
        return {
            size: this.cache.size,
            maxSize: 1000
        };
    }
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = FastMatcher;
} else if (typeof window !== 'undefined') {
    window.FastMatcher = FastMatcher;
    window.fastMatcher = new FastMatcher();
}