/**
 * 智能触发机制模块
 * 基于多维度特征的智能匹配模式选择
 */

/**
 * 智能触发引擎类
 */
class SmartTriggerEngine {
    /**
     * 构造函数
     * @param {Object} options - 配置选项
     * @param {Object} options.fastMatcher - 快速匹配器实例
     * @param {Object} options.deepMatcher - 深度匹配器实例
     * @param {Object} options.semanticMatcher - 语义匹配器实例
     */
    constructor(options = {}) {
        this.fastMatcher = options.fastMatcher;
        this.deepMatcher = options.deepMatcher;
        this.semanticMatcher = options.semanticMatcher;
        this.cache = new Map();
    }
    
    /**
     * 分析输入特征
     * @param {Object} query - 查询条件
     * @returns {Object} 输入特征分析结果
     */
    analyzeInputFeatures(query) {
        const features = {
            hasTitle: Boolean(query.title && query.title.trim()),
            hasDescription: Boolean(query.description && query.description.trim()),
            hasCategory: Boolean(query.category),
            hasLocation: Boolean(query.location && query.location.lat && query.location.lng),
            hasPrice: Boolean(query.price),
            hasTime: Boolean(query.time),
            inputLength: (query.title?.length || 0) + (query.description?.length || 0),
            isComplexQuery: Boolean(
                query.description && query.description.length > 50 ||
                (query.title && query.title.length > 20)
            )
        };
        
        // 计算查询复杂度分数
        features.complexityScore = this.calculateComplexityScore(features);
        
        return features;
    }
    
    /**
     * 计算查询复杂度分数
     * @param {Object} features - 输入特征
     * @returns {number} 复杂度分数 (0-1)
     */
    calculateComplexityScore(features) {
        let score = 0;
        
        if (features.hasTitle) score += 0.1;
        if (features.hasDescription) score += 0.3;
        if (features.hasCategory) score += 0.1;
        if (features.hasLocation) score += 0.1;
        if (features.hasPrice) score += 0.1;
        if (features.hasTime) score += 0.1;
        if (features.inputLength > 50) score += 0.2;
        
        return Math.min(1, score);
    }
    
    /**
     * 识别场景类型
     * @param {Object} query - 查询条件
     * @returns {string} 场景类型
     */
    identifySceneType(query) {
        const features = this.analyzeInputFeatures(query);
        
        if (features.isComplexQuery || features.complexityScore > 0.6) {
            return 'complex';
        } else if (features.hasLocation && features.hasCategory) {
            return 'location_based';
        } else if (features.hasCategory) {
            return 'category_based';
        } else {
            return 'simple';
        }
    }
    
    /**
     * 选择匹配模式
     * @param {Object} query - 查询条件
     * @param {number} resourceCount - 资源数量
     * @returns {string} 匹配模式
     */
    selectMatchingMode(query, resourceCount = 1000) {
        const cacheKey = `trigger_${JSON.stringify(query)}_${resourceCount}`;
        
        // 检查缓存
        if (this.cache.has(cacheKey)) {
            return this.cache.get(cacheKey);
        }
        
        const features = this.analyzeInputFeatures(query);
        const sceneType = this.identifySceneType(query);
        
        let mode = 'fast'; // 默认快速匹配
        
        // 根据场景类型和复杂度选择匹配模式
        if (sceneType === 'complex' || features.complexityScore > 0.7) {
            // 复杂查询使用语义精准匹配
            mode = 'semantic';
        } else if (sceneType === 'location_based' && resourceCount < 500) {
            // 基于位置的查询且资源数量较少时使用深度匹配
            mode = 'deep';
        } else if (features.hasDescription && features.inputLength > 30) {
            // 有详细描述的查询使用深度匹配
            mode = 'deep';
        }
        
        // 缓存结果
        this.cache.set(cacheKey, mode);
        
        return mode;
    }
    
    /**
     * 执行智能匹配
     * @param {Object} query - 查询条件
     * @param {Array} resources - 资源列表
     * @returns {Promise<Array>} 匹配结果
     */
    async executeSmartMatching(query, resources) {
        const mode = this.selectMatchingMode(query, resources.length);
        
        console.log(`智能触发: 选择匹配模式 - ${mode}`);
        
        try {
            switch (mode) {
                case 'semantic':
                    if (this.semanticMatcher) {
                        return await this.semanticMatcher.match(query, resources);
                    } else {
                        // 降级到深度匹配
                        console.warn('语义匹配器不可用，降级到深度匹配');
                        return this.deepMatcher ? 
                            this.deepMatcher.match(query, resources) : 
                            this.fastMatcher.match(query, resources);
                    }
                
                case 'deep':
                    if (this.deepMatcher) {
                        return this.deepMatcher.match(query, resources);
                    } else {
                        // 降级到快速匹配
                        console.warn('深度匹配器不可用，降级到快速匹配');
                        return this.fastMatcher.match(query, resources);
                    }
                
                case 'fast':
                default:
                    if (this.fastMatcher) {
                        return this.fastMatcher.match(query, resources);
                    } else {
                        // 降级到返回原始资源
                        console.warn('快速匹配器不可用，返回原始资源');
                        return resources.slice(0, 20);
                    }
            }
        } catch (error) {
            console.error('智能匹配执行失败:', error);
            // 降级到快速匹配
            if (this.fastMatcher) {
                try {
                    return this.fastMatcher.match(query, resources);
                } catch (fastError) {
                    console.error('快速匹配也失败，返回原始资源:', fastError);
                    return resources.slice(0, 20);
                }
            } else {
                return resources.slice(0, 20);
            }
        }
    }
    
    /**
     * 分析用户行为
     * @param {Array} history - 用户历史查询记录
     * @returns {Object} 用户行为分析结果
     */
    analyzeUserBehavior(history) {
        if (!history || history.length === 0) {
            return {
                preferredMode: 'fast',
                averageComplexity: 0.3,
                hasLocationPreference: false
            };
        }
        
        const analysis = {
            totalQueries: history.length,
            complexQueries: 0,
            locationBasedQueries: 0,
            categoryBasedQueries: 0,
            preferences: {}
        };
        
        history.forEach(query => {
            const features = this.analyzeInputFeatures(query);
            const sceneType = this.identifySceneType(query);
            
            if (features.complexityScore > 0.6) analysis.complexQueries++;
            if (features.hasLocation) analysis.locationBasedQueries++;
            if (features.hasCategory) analysis.categoryBasedQueries++;
            
            // 记录偏好
            if (query.category) {
                analysis.preferences[query.category] = (analysis.preferences[query.category] || 0) + 1;
            }
        });
        
        // 计算偏好模式
        if (analysis.complexQueries / analysis.totalQueries > 0.5) {
            analysis.preferredMode = 'semantic';
        } else if (analysis.locationBasedQueries / analysis.totalQueries > 0.5) {
            analysis.preferredMode = 'deep';
        } else {
            analysis.preferredMode = 'fast';
        }
        
        analysis.averageComplexity = analysis.complexQueries / analysis.totalQueries;
        analysis.hasLocationPreference = analysis.locationBasedQueries / analysis.totalQueries > 0.3;
        
        return analysis;
    }
    
    /**
     * 根据用户行为调整触发策略
     * @param {Object} userBehavior - 用户行为分析结果
     * @returns {Object} 调整后的触发策略
     */
    adjustTriggerStrategy(userBehavior) {
        return {
            preferredMode: userBehavior.preferredMode,
            complexityThreshold: userBehavior.averageComplexity > 0.5 ? 0.6 : 0.7,
            locationBoost: userBehavior.hasLocationPreference ? 0.2 : 0,
            enablePredictiveMatching: userBehavior.totalQueries > 5
        };
    }
    
    /**
     * 清理缓存
     */
    clearCache() {
        this.cache.clear();
    }
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = SmartTriggerEngine;
} else if (typeof window !== 'undefined') {
    window.SmartTriggerEngine = SmartTriggerEngine;
}
