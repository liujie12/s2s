/**
 * 深度匹配模块
 * 实现多维度匹配算法，响应时间不超过 1 秒
 */
class DeepMatcher {
    /**
     * 构造函数
     * @param {Object} options 配置选项
     */
    constructor(options = {}) {
        this.config = {
            maxDistance: options.maxDistance || 50, // 最大搜索距离（km）
            limit: options.limit || 20, // 返回结果数量
            cacheTTL: options.cacheTTL || 3600, // 缓存过期时间（秒）
            weights: {
                distance: options.weights?.distance || 0.3,
                category: options.weights?.category || 0.25,
                price: options.weights?.price || 0.2,
                time: options.weights?.time || 0.15,
                relevance: options.weights?.relevance || 0.1
            },
            ...options
        };
        this.cache = new Map();
        this.fastMatcher = null;
        
        // 尝试加载快速匹配模块
        if (typeof window !== 'undefined' && window.FastMatcher) {
            this.fastMatcher = new window.FastMatcher();
        } else if (typeof module !== 'undefined' && module.require) {
            try {
                const FastMatcher = require('./fastMatcher');
                this.fastMatcher = new FastMatcher();
            } catch (error) {
                console.warn('快速匹配模块未加载，深度匹配将不使用快速预筛选');
            }
        }
    }

    /**
     * 计算两点之间的距离（使用Haversine公式）
     * @param {Array} coord1 第一个坐标 [lng, lat]
     * @param {Array} coord2 第二个坐标 [lng, lat]
     * @returns {number} 距离（公里）
     */
    calculateDistance(coord1, coord2) {
        if (this.fastMatcher) {
            return this.fastMatcher.calculateDistance(coord1, coord2);
        }
        
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
     * 解析价格信息
     * @param {string} priceStr 价格字符串
     * @returns {number|null} 解析后的价格数值
     */
    parsePrice(priceStr) {
        if (!priceStr) return null;
        
        // 提取数字部分
        const priceMatch = priceStr.match(/\d+(\.\d+)?/);
        if (!priceMatch) return null;
        
        return parseFloat(priceMatch[0]);
    }

    /**
     * 计算价格相似度
     * @param {number} resourcePrice 资源价格
     * @param {number} targetPrice 目标价格
     * @param {number} priceRange 价格范围
     * @returns {number} 价格相似度得分 (0-1)
     */
    calculatePriceSimilarity(resourcePrice, targetPrice, priceRange = 1000) {
        if (resourcePrice === null || targetPrice === null) return 0;
        
        const priceDiff = Math.abs(resourcePrice - targetPrice);
        const similarity = Math.max(0, 1 - priceDiff / priceRange);
        return similarity;
    }

    /**
     * 计算时间匹配度
     * @param {string} availableTime 可用时间
     * @param {string} targetTime 目标时间
     * @returns {number} 时间匹配度得分 (0-1)
     */
    calculateTimeMatch(availableTime, targetTime) {
        if (!availableTime || !targetTime) return 0;
        
        const timeKeywords = {
            '随时': ['随时', '立即', '马上'],
            '当天': ['当天', '今日', '今天'],
            '明天': ['明天', '次日'],
            '本周': ['本周', '这周', '本星期'],
            '下周': ['下周', '下星期'],
            '本月': ['本月', '这个月'],
            '下月': ['下月', '下个月']
        };
        
        // 简单的时间匹配逻辑
        const availableLower = availableTime.toLowerCase();
        const targetLower = targetTime.toLowerCase();
        
        // 完全匹配
        if (availableLower.includes(targetLower)) return 1;
        
        // 关键词匹配
        for (const [timeType, keywords] of Object.entries(timeKeywords)) {
            const hasAvailableKeyword = keywords.some(keyword => availableLower.includes(keyword));
            const hasTargetKeyword = keywords.some(keyword => targetLower.includes(keyword));
            
            if (hasAvailableKeyword && hasTargetKeyword) {
                return 0.8;
            }
        }
        
        // 部分匹配
        if (availableLower.includes('可用') && targetLower.includes('可用')) {
            return 0.5;
        }
        
        return 0;
    }

    /**
     * 计算分类匹配度
     * @param {string} resourceCategory 资源分类
     * @param {string} targetCategory 目标分类
     * @param {Object} categoryTree 分类树结构
     * @returns {number} 分类匹配度得分 (0-1)
     */
    calculateCategoryMatch(resourceCategory, targetCategory, categoryTree = {}) {
        if (!resourceCategory || !targetCategory) return 0;
        
        // 完全匹配
        if (resourceCategory === targetCategory) return 1;
        
        // 子分类匹配
        for (const parent in categoryTree) {
            if (categoryTree.hasOwnProperty(parent)) {
                const children = categoryTree[parent];
                // 检查是否属于同一父分类
                if (children.includes(resourceCategory) && children.includes(targetCategory)) {
                    return 0.8;
                }
                // 检查是否为父子分类关系
                if (parent === targetCategory && children.includes(resourceCategory)) {
                    return 0.7;
                }
                if (parent === resourceCategory && children.includes(targetCategory)) {
                    return 0.7;
                }
            }
        }
        
        // 部分匹配
        if (resourceCategory.includes(targetCategory) || targetCategory.includes(resourceCategory)) {
            return 0.5;
        }
        
        return 0;
    }

    /**
     * 计算文本相关性
     * @param {string} text 资源文本
     * @param {string} query 查询文本
     * @returns {number} 文本相关性得分 (0-1)
     */
    calculateTextRelevance(text, query) {
        if (!text || !query) return 0;
        
        const textLower = text.toLowerCase();
        const queryLower = query.toLowerCase();
        
        // 完全匹配
        if (textLower.includes(queryLower)) return 1;
        
        // 关键词匹配
        const queryWords = queryLower.split(/\s+/).filter(word => word.length > 1);
        if (queryWords.length === 0) return 0;
        
        let matchedWords = 0;
        for (const word of queryWords) {
            if (textLower.includes(word)) {
                matchedWords++;
            }
        }
        
        return matchedWords / queryWords.length;
    }

    /**
     * 计算综合匹配得分
     * @param {Object} resource 资源对象
     * @param {Object} params 查询参数
     * @returns {number} 综合匹配得分 (0-1)
     */
    calculateMatchScore(resource, params) {
        const { location, category, query, price, time } = params;
        const { weights } = this.config;
        
        let totalScore = 0;
        let totalWeight = 0;
        
        // 距离得分
        if (location && location.lat && location.lng && resource.coordinates) {
            const distance = this.calculateDistance(
                [location.lng, location.lat],
                resource.coordinates
            );
            if (distance <= this.config.maxDistance) {
                const distanceScore = Math.max(0, 1 - distance / this.config.maxDistance);
                totalScore += distanceScore * weights.distance;
                totalWeight += weights.distance;
            } else {
                // 超出距离范围，直接返回0
                return 0;
            }
        }
        
        // 分类得分
        if (category && category !== 'all') {
            const categoryScore = this.calculateCategoryMatch(resource.category, category);
            totalScore += categoryScore * weights.category;
            totalWeight += weights.category;
        }
        
        // 价格得分
        if (price) {
            const resourcePrice = this.parsePrice(resource.price);
            const targetPrice = typeof price === 'string' ? this.parsePrice(price) : price;
            if (resourcePrice !== null && targetPrice !== null) {
                const priceScore = this.calculatePriceSimilarity(resourcePrice, targetPrice);
                totalScore += priceScore * weights.price;
                totalWeight += weights.price;
            }
        }
        
        // 时间得分
        if (time) {
            const timeScore = this.calculateTimeMatch(resource.availableTime, time);
            totalScore += timeScore * weights.time;
            totalWeight += weights.time;
        }
        
        // 相关性得分
        if (query) {
            const textContent = `${resource.title} ${resource.description} ${resource.tags?.join(' ') || ''}`;
            const relevanceScore = this.calculateTextRelevance(textContent, query);
            totalScore += relevanceScore * weights.relevance;
            totalWeight += weights.relevance;
        }
        
        // 归一化得分
        if (totalWeight === 0) return 0;
        return totalScore / totalWeight;
    }

    /**
     * 生成缓存键
     * @param {Object} params 查询参数
     * @returns {string} 缓存键
     */
    generateCacheKey(params) {
        const { query, location, category, radius, price, time } = params;
        return `${query || ''}_${location?.lat || ''}_${location?.lng || ''}_${category || ''}_${radius || ''}_${price || ''}_${time || ''}`;
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
     * 执行深度匹配
     * @param {Array} resources 资源列表
     * @param {Object} params 查询参数
     * @param {Object} options 选项
     * @returns {Object} 深度匹配结果
     */
    match(resources, params, options = {}) {
        const startTime = Date.now();
        
        // 生成缓存键
        const cacheKey = this.generateCacheKey(params);
        
        // 检查缓存
        const cachedResult = this.checkCache(cacheKey);
        if (cachedResult) {
            console.log('深度匹配: 使用缓存结果');
            return {
                ...cachedResult,
                time: Date.now() - startTime,
                cached: true
            };
        }
        
        let filteredResources = resources;
        
        // 使用快速匹配进行预筛选（如果可用）
        if (this.fastMatcher) {
            console.log('深度匹配: 使用快速匹配进行预筛选');
            const fastResult = this.fastMatcher.match(resources, params, { limit: 100 });
            filteredResources = fastResult.results;
        }
        
        // 计算每个资源的匹配得分
        const scoredResources = filteredResources.map(resource => {
            const score = this.calculateMatchScore(resource, params);
            return {
                ...resource,
                matchScore: score,
                matchDetails: {
                    distance: params.location && resource.coordinates ? 
                        this.calculateDistance(
                            [params.location.lng, params.location.lat],
                            resource.coordinates
                        ) : null,
                    category: resource.category === params.category ? 1 : 0,
                    price: this.parsePrice(resource.price),
                    time: resource.availableTime
                }
            };
        });
        
        // 按匹配得分排序
        scoredResources.sort((a, b) => b.matchScore - a.matchScore);
        
        // 限制返回数量
        const limitedResources = scoredResources.slice(0, this.config.limit);
        
        // 生成结果
        const result = {
            results: limitedResources,
            total: scoredResources.length,
            time: Date.now() - startTime,
            cached: false
        };
        
        // 设置缓存
        this.setCache(cacheKey, result);
        
        console.log(`深度匹配: 处理了 ${resources.length} 个资源，快速筛选到 ${filteredResources.length} 个，返回 ${limitedResources.length} 个结果，耗时 ${result.time}ms`);
        
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
    module.exports = DeepMatcher;
} else if (typeof window !== 'undefined') {
    window.DeepMatcher = DeepMatcher;
    window.deepMatcher = new DeepMatcher();
}
