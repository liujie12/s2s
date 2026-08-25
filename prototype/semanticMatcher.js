/**
 * 语义精准匹配模块
 * 实现基于大模型语义理解的深度匹配
 * 响应时间目标：不超过 2 秒（95% 分位）
 */

/**
 * 语义匹配器类
 */
class SemanticMatcher {
    /**
     * 构造函数
     * @param {Object} options - 配置选项
     * @param {number} options.timeout - 请求超时时间（毫秒）
     * @param {number} options.maxResults - 最大匹配结果数
     * @param {number} options.minRelevanceScore - 最小相关度分数
     */
    constructor(options = {}) {
        this.timeout = options.timeout || 2000; // 2秒超时
        this.maxResults = options.maxResults || 20;
        this.minRelevanceScore = options.minRelevanceScore || 0.05; // 降低阈值以提高匹配率
        this.cache = new Map();
        this.fastMatcher = null;
        
        // 初始化向量存储
        this.vectorStorage = new Map();
    }
    
    /**
     * 设置快速匹配器
     * @param {Object} fastMatcher - 快速匹配器实例
     */
    setFastMatcher(fastMatcher) {
        this.fastMatcher = fastMatcher;
    }
    
    /**
     * 获取语义向量（模拟）
     * @param {string} text - 文本内容
     * @returns {Promise<Array>} 语义向量
     */
    async getSemanticVector(text) {
        const cacheKey = `vector_${text}`;
        
        // 检查缓存
        if (this.cache.has(cacheKey)) {
            return this.cache.get(cacheKey);
        }
        
        try {
            // 模拟大模型API调用
            // 实际项目中这里应该调用真实的大模型API
            const vector = await this.mockSemanticVectorization(text);
            
            // 缓存结果
            this.cache.set(cacheKey, vector);
            
            return vector;
        } catch (error) {
            console.error('语义向量获取失败:', error);
            // 降级策略：使用简单的词频向量
            return this.fallbackVectorization(text);
        }
    }
    
    /**
     * 模拟语义向量化（用于测试）
     * @param {string} text - 文本内容
     * @returns {Promise<Array>} 模拟语义向量
     */
    async mockSemanticVectorization(text) {
        return new Promise((resolve) => {
            // 模拟API延迟
            setTimeout(() => {
                // 生成随机向量（实际项目中应该是真实的语义向量）
                const vector = [];
                for (let i = 0; i < 128; i++) {
                    vector.push(Math.random() * 2 - 1);
                }
                resolve(vector);
            }, 100); // 模拟100ms延迟
        });
    }
    
    /**
     * 降级向量化策略
     * @param {string} text - 文本内容
     * @returns {Array} 降级语义向量
     */
    fallbackVectorization(text) {
        // 简单的词频向量化
        const words = text.toLowerCase().split(/\s+/);
        const wordCount = {};
        
        words.forEach(word => {
            if (word) {
                wordCount[word] = (wordCount[word] || 0) + 1;
            }
        });
        
        // 生成固定长度的向量
        const vector = [];
        for (let i = 0; i < 128; i++) {
            vector.push(0);
        }
        
        // 填充向量
        let index = 0;
        for (const word in wordCount) {
            if (index < 128) {
                vector[index] = wordCount[word] / words.length;
                index++;
            } else {
                break;
            }
        }
        
        return vector;
    }
    
    /**
     * 计算余弦相似度
     * @param {Array} vector1 - 向量1
     * @param {Array} vector2 - 向量2
     * @returns {number} 余弦相似度
     */
    calculateCosineSimilarity(vector1, vector2) {
        if (vector1.length !== vector2.length) {
            throw new Error('向量长度不匹配');
        }
        
        let dotProduct = 0;
        let norm1 = 0;
        let norm2 = 0;
        
        for (let i = 0; i < vector1.length; i++) {
            dotProduct += vector1[i] * vector2[i];
            norm1 += vector1[i] * vector1[i];
            norm2 += vector2[i] * vector2[i];
        }
        
        norm1 = Math.sqrt(norm1);
        norm2 = Math.sqrt(norm2);
        
        if (norm1 === 0 || norm2 === 0) {
            return 0;
        }
        
        return dotProduct / (norm1 * norm2);
    }
    
    /**
     * 存储语义向量
     * @param {string} id - 资源/需求ID
     * @param {Array} vector - 语义向量
     */
    storeSemanticVector(id, vector) {
        this.vectorStorage.set(id, vector);
    }
    
    /**
     * 检索相似资源
     * @param {Array} queryVector - 查询向量
     * @param {Array} resources - 资源列表
     * @param {number} topK - 返回前K个结果
     * @returns {Array} 相似资源列表
     */
    retrieveSimilarResources(queryVector, resources, topK = 20) {
        const similarities = [];
        
        resources.forEach(resource => {
            try {
                // 获取或计算资源的语义向量
                let resourceVector = this.vectorStorage.get(resource.id);
                
                if (!resourceVector) {
                    // 如果没有存储向量，使用降级策略
                    resourceVector = this.fallbackVectorization(
                        `${resource.title} ${resource.description}`
                    );
                    // 存储计算结果
                    this.storeSemanticVector(resource.id, resourceVector);
                }
                
                // 计算相似度
                const similarity = this.calculateCosineSimilarity(
                    queryVector, 
                    resourceVector
                );
                
                if (similarity >= this.minRelevanceScore) {
                    similarities.push({
                        resource,
                        similarity
                    });
                }
            } catch (error) {
                console.error('计算资源相似度失败:', error);
            }
        });
        
        // 按相似度排序并返回前K个
        similarities.sort((a, b) => b.similarity - a.similarity);
        
        return similarities.slice(0, topK).map(item => ({
            ...item.resource,
            semanticScore: item.similarity
        }));
    }
    
    /**
     * 语义精准匹配
     * @param {Object} query - 查询条件
     * @param {Array} resources - 资源列表
     * @returns {Promise<Array>} 匹配结果
     */
    async match(query, resources) {
        const startTime = performance.now();
        
        try {
            // 1. 首先使用快速匹配进行预筛选（如果可用）
            let filteredResources = resources;
            if (this.fastMatcher) {
                try {
                    filteredResources = this.fastMatcher.match(query, resources);
                    console.log(`快速匹配筛选后资源数: ${filteredResources.length}`);
                } catch (error) {
                    console.warn('快速匹配失败，使用原始资源列表:', error);
                    // 快速匹配失败时使用原始资源列表
                }
            }
            
            console.log(`开始语义匹配，资源数: ${filteredResources.length}`);
            
            // 2. 生成查询向量
            const queryText = `${query.title || ''} ${query.description || ''} ${query.tags || ''}`;
            const queryVector = await this.getSemanticVector(queryText);
            
            // 3. 检索相似资源
            const semanticResults = this.retrieveSimilarResources(
                queryVector, 
                filteredResources, 
                this.maxResults
            );
            
            console.log(`语义检索结果数: ${semanticResults.length}`);
            
            // 4. 添加多维度评分
            const results = semanticResults.map(resource => {
                // 计算综合评分
                const comprehensiveScore = this.calculateComprehensiveScore(resource, query);
                
                return {
                    ...resource,
                    matchScore: comprehensiveScore,
                    matchReasons: this.generateMatchReasons(resource, query)
                };
            });
            
            // 5. 按综合评分排序
            results.sort((a, b) => b.matchScore - a.matchScore);
            
            const endTime = performance.now();
            console.log(`语义匹配完成，耗时: ${(endTime - startTime).toFixed(2)}ms, 结果数: ${results.length}`);
            
            // 如果没有匹配结果，返回原始资源列表的前几个
            if (results.length === 0 && filteredResources.length > 0) {
                console.log('无语义匹配结果，返回原始资源');
                return filteredResources.slice(0, this.maxResults).map(resource => ({
                    ...resource,
                    matchScore: 0,
                    matchReasons: ['无语义匹配，返回原始资源']
                }));
            }
            
            return results;
        } catch (error) {
            console.error('语义匹配失败:', error);
            // 降级策略：使用快速匹配结果
            if (this.fastMatcher) {
                console.log('使用快速匹配结果作为降级策略');
                return this.fastMatcher.match(query, resources);
            }
            // 如果快速匹配也不可用，返回原始资源列表
            return resources.slice(0, this.maxResults);
        }
    }
    
    /**
     * 计算综合评分
     * @param {Object} resource - 资源
     * @param {Object} query - 查询条件
     * @returns {number} 综合评分
     */
    calculateComprehensiveScore(resource, query) {
        // 语义评分权重
        const semanticWeight = 0.6;
        // 距离评分权重
        const distanceWeight = 0.2;
        // 分类评分权重
        const categoryWeight = 0.2;
        
        // 语义评分（已计算）
        const semanticScore = resource.semanticScore || 0;
        
        // 距离评分
        let distanceScore = 1.0;
        if (query.location && resource.location) {
            try {
                const distance = this.calculateDistance(
                    query.location.lat, query.location.lng,
                    resource.location.lat, resource.location.lng
                );
                // 距离越近分数越高
                distanceScore = Math.max(0, 1 - distance / 10000); // 10公里内满分
            } catch (error) {
                console.error('计算距离失败:', error);
            }
        }
        
        // 分类评分
        let categoryScore = 0;
        if (query.category && resource.category) {
            if (query.category === resource.category) {
                categoryScore = 1.0;
            } else if (resource.category.includes(query.category) || 
                      query.category.includes(resource.category)) {
                categoryScore = 0.7;
            }
        }
        
        // 计算综合评分
        const comprehensiveScore = (
            semanticScore * semanticWeight +
            distanceScore * distanceWeight +
            categoryScore * categoryWeight
        );
        
        return comprehensiveScore;
    }
    
    /**
     * 计算两点之间的距离（Haversine公式）
     * @param {number} lat1 - 纬度1
     * @param {number} lng1 - 经度1
     * @param {number} lat2 - 纬度2
     * @param {number} lng2 - 经度2
     * @returns {number} 距离（米）
     */
    calculateDistance(lat1, lng1, lat2, lng2) {
        const R = 6371e3; // 地球半径（米）
        const φ1 = (lat1 * Math.PI) / 180;
        const φ2 = (lat2 * Math.PI) / 180;
        const Δφ = ((lat2 - lat1) * Math.PI) / 180;
        const Δλ = ((lng2 - lng1) * Math.PI) / 180;
        
        const a =
            Math.sin(Δφ / 2) * Math.sin(Δφ / 2) +
            Math.cos(φ1) * Math.cos(φ2) * Math.sin(Δλ / 2) * Math.sin(Δλ / 2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        
        return R * c;
    }
    
    /**
     * 生成匹配原因
     * @param {Object} resource - 资源
     * @param {Object} query - 查询条件
     * @returns {Array} 匹配原因列表
     */
    generateMatchReasons(resource, query) {
        const reasons = [];
        
        // 语义匹配原因
        if (resource.semanticScore && resource.semanticScore > 0.5) {
            reasons.push(`语义相似度高 (${(resource.semanticScore * 100).toFixed(0)}%)`);
        }
        
        // 距离匹配原因
        if (query.location && resource.location) {
            try {
                const distance = this.calculateDistance(
                    query.location.lat, query.location.lng,
                    resource.location.lat, resource.location.lng
                );
                
                if (distance < 1000) {
                    reasons.push(`距离很近 (${(distance / 1000).toFixed(1)}公里)`);
                } else if (distance < 5000) {
                    reasons.push(`距离较近 (${(distance / 1000).toFixed(1)}公里)`);
                }
            } catch (error) {
                // 忽略距离计算错误
            }
        }
        
        // 分类匹配原因
        if (query.category && resource.category) {
            if (query.category === resource.category) {
                reasons.push('分类完全匹配');
            } else if (resource.category.includes(query.category) || 
                      query.category.includes(resource.category)) {
                reasons.push('分类相关');
            }
        }
        
        return reasons;
    }
    
    /**
     * 清理缓存
     */
    clearCache() {
        this.cache.clear();
        this.vectorStorage.clear();
    }
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = SemanticMatcher;
} else if (typeof window !== 'undefined') {
    window.SemanticMatcher = SemanticMatcher;
}
