/**
 * 多维度匹配算法
 * 实现基于距离、分类、价格、时间、语义等多维度的智能匹配
 */
class MatchingAlgorithm {
    /**
     * 构造函数
     * @param {Object} options 配置选项
     */
    constructor(options = {}) {
        // 权重配置
        this.weights = {
            distance: options.distanceWeight || 0.25,    // 距离权重
            category: options.categoryWeight || 0.25,    // 分类权重
            semantic: options.semanticWeight || 0.2,     // 语义匹配权重
            price: options.priceWeight || 0.15,       // 价格权重
            time: options.timeWeight || 0.05,        // 时间权重
            rating: options.ratingWeight || 0.1       // 信誉评分权重
        };
        
        // 语义匹配器实例
        this.semanticMatcher = options.semanticMatcher || (typeof window !== 'undefined' && window.semanticMatcher);
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
     * 计算距离匹配分数
     * @param {number} distance 距离（公里）
     * @param {number} maxDistance 最大距离（公里）
     * @returns {number} 距离匹配分数（0-1）
     */
    calculateDistanceScore(distance, maxDistance = 50) {
        if (distance >= maxDistance) return 0;
        if (distance <= 1) return 1;
        return 1 - (distance / maxDistance);
    }

    /**
     * 计算分类匹配分数
     * @param {string} resourceCategory 资源分类
     * @param {string} demandCategory 需求分类
     * @param {Object} categoryTree 分类树结构
     * @returns {number} 分类匹配分数（0-1）
     */
    calculateCategoryScore(resourceCategory, demandCategory, categoryTree = {}) {
        if (!resourceCategory || !demandCategory) return 0;
        
        // 完全匹配
        if (resourceCategory === demandCategory) return 1;
        
        // 检查子分类匹配
        for (const parent in categoryTree) {
            if (categoryTree.hasOwnProperty(parent)) {
                const children = categoryTree[parent];
                if (children.includes(resourceCategory) && children.includes(demandCategory)) {
                    return 0.8;
                }
                if (parent === resourceCategory && children.includes(demandCategory)) {
                    return 0.7;
                }
                if (parent === demandCategory && children.includes(resourceCategory)) {
                    return 0.7;
                }
            }
        }
        
        // 部分匹配（关键词相似度）
        const similarity = this.calculateStringSimilarity(resourceCategory, demandCategory);
        return similarity * 0.6;
    }

    /**
     * 计算字符串相似度
     * @param {string} str1 字符串1
     * @param {string} str2 字符串2
     * @returns {number} 相似度（0-1）
     */
    calculateStringSimilarity(str1, str2) {
        if (!str1 || !str2) return 0;
        if (str1 === str2) return 1;
        
        // 简单的关键词匹配
        const words1 = str1.split(/\s+/);
        const words2 = str2.split(/\s+/);
        let matchCount = 0;
        
        for (const word1 of words1) {
            if (words2.some(word2 => word2.includes(word1) || word1.includes(word2))) {
                matchCount++;
            }
        }
        
        return matchCount / Math.max(words1.length, words2.length);
    }

    /**
     * 解析价格字符串为数字
     * @param {string} priceStr 价格字符串，如"80元/小时"
     * @returns {number} 解析后的价格数字
     */
    parsePrice(priceStr) {
        if (!priceStr) return 0;
        
        // 提取数字部分
        const match = priceStr.match(/\d+(\.\d+)?/);
        return match ? parseFloat(match[0]) : 0;
    }

    /**
     * 计算价格匹配分数
     * @param {string} resourcePrice 资源价格
     * @param {number} demandBudget 需求预算
     * @returns {number} 价格匹配分数（0-1）
     */
    calculatePriceScore(resourcePrice, demandBudget) {
        if (!resourcePrice || !demandBudget) return 0.5;
        
        const price = this.parsePrice(resourcePrice);
        const budget = parseFloat(demandBudget) || 0;
        
        if (budget === 0) return 0.5;
        
        const ratio = price / budget;
        if (ratio <= 0.8) return 1; // 价格低于预算20%以上
        if (ratio <= 1) return 0.9; // 价格在预算范围内
        if (ratio <= 1.2) return 0.7; // 价格超出预算20%以内
        if (ratio <= 1.5) return 0.5; // 价格超出预算50%以内
        return 0.2; // 价格超出预算50%以上
    }

    /**
     * 计算时间匹配分数
     * @param {string} resourceTime 资源可用时间
     * @param {string} demandTime 需求时间
     * @returns {number} 时间匹配分数（0-1）
     */
    calculateTimeScore(resourceTime, demandTime) {
        if (!resourceTime || !demandTime) return 0.5;
        
        // 简单的时间匹配逻辑
        const timeKeywords = {
            '今天': ['今天', '现在', '立刻', '马上'],
            '明天': ['明天', '明日'],
            '本周': ['本周', '这星期', '最近几天'],
            '本月': ['本月', '这个月'],
            '长期': ['长期', '永久', '一直', '持续']
        };
        
        // 检查是否有时间关键词匹配
        for (const time in timeKeywords) {
            if (timeKeywords.hasOwnProperty(time)) {
                const keywords = timeKeywords[time];
                const resourceMatch = keywords.some(keyword => resourceTime.includes(keyword));
                const demandMatch = keywords.some(keyword => demandTime.includes(keyword));
                
                if (resourceMatch && demandMatch) {
                    return 1;
                }
            }
        }
        
        // 部分时间匹配
        const similarity = this.calculateStringSimilarity(resourceTime, demandTime);
        return similarity * 0.6;
    }

    /**
     * 计算综合匹配分数
     * @param {Object} resource 资源对象
     * @param {Object} demand 需求对象
     * @param {Object} options 选项
     * @returns {number} 综合匹配分数（0-1）
     */
    calculateMatchScore(resource, demand, options = {}) {
        // 计算距离分数
        const resourceCoord = resource.coordinates || [0, 0];
        const demandCoord = demand.coordinates || [0, 0];
        const distance = this.calculateDistance(resourceCoord, demandCoord);
        const distanceScore = this.calculateDistanceScore(distance, options.maxDistance);
        
        // 计算分类分数
        const categoryScore = this.calculateCategoryScore(
            resource.category, 
            demand.category, 
            options.categoryTree
        );
        
        // 计算语义匹配分数
        let semanticScore = 0.5; // 默认分数
        if (this.semanticMatcher && demand.title) {
            // 使用预计算的语义分数或默认值
            semanticScore = resource.semanticScore || 0.5;
        }
        
        // 计算价格分数
        const priceScore = this.calculatePriceScore(resource.price, demand.budget);
        
        // 计算时间分数
        const timeScore = this.calculateTimeScore(resource.availableTime, demand.requiredTime);
        
        // 计算信誉评分分数
        const ratingScore = resource.rating ? parseFloat(resource.rating) / 5 : 0.5;
        
        // 计算加权平均分
        const totalScore = (
            distanceScore * this.weights.distance +
            categoryScore * this.weights.category +
            semanticScore * this.weights.semantic +
            priceScore * this.weights.price +
            timeScore * this.weights.time +
            ratingScore * this.weights.rating
        );
        
        return totalScore;
    }

    /**
     * 生成匹配原因
     * @param {Object} resource 资源对象
     * @param {Object} demand 需求对象
     * @param {number} score 匹配分数
     * @returns {Array} 匹配原因数组
     */
    generateMatchReasons(resource, demand, score) {
        const reasons = [];
        
        // 距离原因
        if (resource.coordinates && demand.coordinates) {
            const distance = this.calculateDistance(resource.coordinates, demand.coordinates);
            if (distance < 5) {
                reasons.push('距离很近');
            } else if (distance < 15) {
                reasons.push('距离适中');
            }
        }
        
        // 分类原因
        if (resource.category && demand.category) {
            if (resource.category === demand.category) {
                reasons.push('分类完全匹配');
            } else if (resource.category.includes(demand.category) || demand.category.includes(resource.category)) {
                reasons.push('分类相关');
            }
        }
        
        // 价格原因
        if (resource.price && demand.budget) {
            const price = parseFloat(resource.price) || 0;
            const budget = parseFloat(demand.budget) || 0;
            if (price <= budget) {
                reasons.push('价格在预算范围内');
            }
        }
        
        // 时间原因
        if (resource.availableTime && demand.requiredTime) {
            if (resource.availableTime.includes(demand.requiredTime) || demand.requiredTime.includes(resource.availableTime)) {
                reasons.push('时间匹配');
            }
        }
        
        // 信誉原因
        if (resource.rating) {
            const rating = parseFloat(resource.rating);
            if (rating >= 4.5) {
                reasons.push('信誉评分高');
            }
        }
        
        // 默认原因
        if (reasons.length === 0) {
            if (score >= 0.8) {
                reasons.push('综合匹配度高');
            } else if (score >= 0.6) {
                reasons.push('综合匹配度中等');
            } else {
                reasons.push('有一定匹配度');
            }
        }
        
        return reasons;
    }

    /**
     * 执行多维度匹配
     * @param {Array} resources 资源列表
     * @param {Object} demand 需求对象
     * @param {Object} options 选项
     * @returns {Promise<Array>} 排序后的资源列表
     */
    async match(resources, demand, options = {}) {
        let resourcesWithSemanticScores = resources;
        
        // 执行语义匹配（如果有语义匹配器且有查询文本）
        if (this.semanticMatcher && demand.title) {
            try {
                resourcesWithSemanticScores = await this.semanticMatcher.match(resources, demand.title);
            } catch (error) {
                console.error('语义匹配失败:', error);
                // 失败时继续使用原始资源列表
            }
        }
        
        // 计算每个资源的综合匹配分数
        const resourcesWithScores = resourcesWithSemanticScores.map(resource => {
            const score = this.calculateMatchScore(resource, demand, options);
            
            // 合并匹配原因
            const matchReasons = [
                ...this.generateMatchReasons(resource, demand, score),
                ...(resource.semanticMatchReasons || [])
            ].slice(0, 3); // 最多显示3个原因
            
            return {
                ...resource,
                matchScore: score,
                finalMatchScore: score, // 综合匹配分数
                matchReasons
            };
        });

        // 按匹配分数排序
        resourcesWithScores.sort((a, b) => b.matchScore - a.matchScore);

        return resourcesWithScores;
    }
}

// 导出算法实例
if (typeof module !== 'undefined' && module.exports) {
    module.exports = MatchingAlgorithm;
} else if (typeof window !== 'undefined') {
    window.MatchingAlgorithm = MatchingAlgorithm;
    window.matchingAlgorithm = new MatchingAlgorithm();
}
