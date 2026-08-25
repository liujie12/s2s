/**
 * 语义精准匹配模块
 * 基于大模型语义理解的深度匹配，响应时间不超过2秒
 */
class SemanticPreciseMatcher {
    /**
     * 构造函数
     * @param {Object} options 配置选项
     */
    constructor(options = {}) {
        this.config = {
            llmEndpoint: options.llmEndpoint || 'https://api.example.com/llm',
            apiKey: options.apiKey || '',
            cacheSize: options.cacheSize || 500,
            limit: options.limit || 5,
            vectorStoreType: options.vectorStoreType || 'memory', // memory, redis, faiss
            ...options
        };
        
        // 初始化缓存
        this.cache = new Map();
        
        // 初始化向量存储
        this.vectorStore = this.initVectorStore();
    }

    /**
     * 初始化向量存储
     * @returns {Object} 向量存储实例
     */
    initVectorStore() {
        switch (this.config.vectorStoreType) {
            case 'redis':
                // 实际项目中应替换为真实的Redis客户端
                return this.createMockRedisStore();
            case 'faiss':
                // 实际项目中应替换为真实的FAISS实例
                return this.createMockFaissStore();
            case 'memory':
            default:
                return this.createMemoryStore();
        }
    }

    /**
     * 创建内存向量存储
     * @returns {Object} 内存向量存储实例
     */
    createMemoryStore() {
        return {
            vectors: new Map(),
            
            async add(id, vector, metadata) {
                this.vectors.set(id, { vector, metadata });
            },
            
            async search(queryVector, k = 5) {
                const results = [];
                
                for (const [id, { vector, metadata }] of this.vectors.entries()) {
                    const similarity = this.calculateCosineSimilarity(queryVector, vector);
                    results.push({ id, similarity, metadata });
                }
                
                results.sort((a, b) => b.similarity - a.similarity);
                return results.slice(0, k);
            },
            
            async clear() {
                this.vectors.clear();
            }
        };
    }

    /**
     * 创建模拟Redis向量存储
     * @returns {Object} 模拟Redis向量存储实例
     */
    createMockRedisStore() {
        return this.createMemoryStore(); // 简化处理，使用内存存储模拟
    }

    /**
     * 创建模拟FAISS向量存储
     * @returns {Object} 模拟FAISS向量存储实例
     */
    createMockFaissStore() {
        return this.createMemoryStore(); // 简化处理，使用内存存储模拟
    }

    /**
     * 生成模拟的向量嵌入
     * @param {string} text 输入文本
     * @returns {Array} 模拟的向量嵌入
     */
    generateMockEmbedding(text) {
        // 生成固定长度的随机向量作为模拟嵌入
        const embeddingLength = 100;
        const embedding = [];
        
        // 基于文本内容生成伪随机向量
        let seed = 0;
        for (let i = 0; i < text.length; i++) {
            seed += text.charCodeAt(i);
        }
        
        for (let i = 0; i < embeddingLength; i++) {
            // 使用简单的哈希函数生成伪随机值
            const value = (Math.sin(seed * (i + 1)) * 0.5 + 0.5).toFixed(6);
            embedding.push(parseFloat(value));
        }
        
        return embedding;
    }

    /**
     * 计算两个向量的余弦相似度
     * @param {Array} vec1 第一个向量
     * @param {Array} vec2 第二个向量
     * @returns {number} 余弦相似度（-1到1）
     */
    calculateCosineSimilarity(vec1, vec2) {
        if (!vec1 || !vec2 || vec1.length !== vec2.length) {
            return 0;
        }
        
        let dotProduct = 0;
        let norm1 = 0;
        let norm2 = 0;
        
        for (let i = 0; i < vec1.length; i++) {
            dotProduct += vec1[i] * vec2[i];
            norm1 += vec1[i] * vec1[i];
            norm2 += vec2[i] * vec2[i];
        }
        
        norm1 = Math.sqrt(norm1);
        norm2 = Math.sqrt(norm2);
        
        if (norm1 === 0 || norm2 === 0) {
            return 0;
        }
        
        return dotProduct / (norm1 * norm2);
    }

    /**
     * 提取关键词
     * @param {string} text 输入文本
     * @returns {Array} 提取的关键词列表
     */
    extractKeywords(text) {
        const stopWords = ['的', '了', '是', '在', '有', '和', '就', '不', '人', '都', '一', '一个', '上', '也', '很', '到', '说', '去', '你', '会', '着', '没有', '看', '好', '自己', '这'];
        return text.toLowerCase().split(/[\s，,]+/)
            .filter(word => word.length > 1 && !stopWords.includes(word));
    }

    /**
     * 提取实体
     * @param {string} text 输入文本
     * @returns {Array} 提取的实体列表
     */
    extractEntities(text) {
        const entities = [];
        
        // 提取地点实体
        const locationPatterns = [/在(.+?)附近/, /(北京|上海|广州|深圳|杭州|成都|武汉|西安)\s*的?/, /(朝阳区|海淀区|东城区|西城区|丰台区|石景山区|门头沟区|房山区|通州区|顺义区|昌平区|大兴区|怀柔区|平谷区|密云区|延庆区)/];
        for (const pattern of locationPatterns) {
            const matches = text.match(pattern);
            if (matches) {
                entities.push({
                    type: 'location',
                    value: matches[1] || matches[0]
                });
            }
        }
        
        // 提取时间实体
        const timePatterns = [/今天|明天|后天|本周|下周|本月|下月|(\d+)月(\d+)日|(\d+)点(\d+)?分/];
        for (const pattern of timePatterns) {
            const matches = text.match(pattern);
            if (matches) {
                entities.push({
                    type: 'time',
                    value: matches[0]
                });
            }
        }
        
        // 提取价格实体
        const pricePatterns = [/(\d+)元|(\d+)块|(\d+)人民币/];
        for (const pattern of pricePatterns) {
            const matches = text.match(pattern);
            if (matches) {
                entities.push({
                    type: 'price',
                    value: matches[0]
                });
            }
        }
        
        return entities;
    }

    /**
     * 检测意图
     * @param {string} text 输入文本
     * @returns {string} 检测到的意图
     */
    detectIntent(text) {
        const intents = {
            search: ['找', '寻找', '求', '需要', '想要', '急需', '请求', '申请', '推荐', '附近'],
            provide: ['提供', '出租', '出售', '转让', '共享', '交换', '兼职', '服务'],
            inquiry: ['多少钱', '价格', '费用', '怎么收费', '联系方式', '电话'],
            comparison: ['最便宜', '最好', '最专业', '性价比最高', '对比']
        };
        
        for (const [intent, keywords] of Object.entries(intents)) {
            for (const keyword of keywords) {
                if (text.includes(keyword)) {
                    return intent;
                }
            }
        }
        
        return 'search'; // 默认意图
    }

    /**
     * 调用大模型服务进行语义理解
     * @param {string} text 输入文本
     * @returns {Promise<Object>} 语义理解结果
     */
    async getSemanticEmbedding(text) {
        // 检查缓存
        if (this.cache.has(text)) {
            return this.cache.get(text);
        }

        console.log('调用大模型进行语义理解:', text);

        // 模拟大模型API调用，实际项目中应替换为真实的API调用
        return new Promise((resolve) => {
            setTimeout(() => {
                // 模拟语义理解结果
                const embedding = this.generateMockEmbedding(text);
                const entities = this.extractEntities(text);
                const intent = this.detectIntent(text);
                
                const result = {
                    embedding,
                    entities,
                    intent,
                    keywords: this.extractKeywords(text),
                    confidence: 0.95
                };

                // 缓存结果
                if (this.cache.size >= this.config.cacheSize) {
                    // 移除最早的缓存项
                    const firstKey = this.cache.keys().next().value;
                    this.cache.delete(firstKey);
                }
                this.cache.set(text, result);

                console.log('语义理解结果:', result);
                resolve(result);
            }, 500); // 模拟500ms响应时间
        });
    }

    /**
     * 计算语义匹配分数
     * @param {string} text1 第一个文本
     * @param {string} text2 第二个文本
     * @returns {Promise<number>} 语义匹配分数（0-1）
     */
    async calculateSemanticScore(text1, text2) {
        try {
            const embedding1 = await this.getSemanticEmbedding(text1);
            const embedding2 = await this.getSemanticEmbedding(text2);
            
            const similarity = this.calculateCosineSimilarity(embedding1.embedding, embedding2.embedding);
            // 将相似度从[-1,1]映射到[0,1]
            return (similarity + 1) / 2;
        } catch (error) {
            console.error('计算语义匹配分数失败:', error);
            return 0.5; // 失败时返回默认分数
        }
    }

    /**
     * 生成语义匹配原因
     * @param {Object} resource 资源对象
     * @param {string} query 查询文本
     * @param {number} score 语义匹配分数
     * @returns {Array} 语义匹配原因数组
     */
    generateSemanticMatchReasons(resource, query, score) {
        const reasons = [];
        
        // 基于分数生成原因
        if (score >= 0.85) {
            reasons.push('语义高度相关');
        } else if (score >= 0.7) {
            reasons.push('语义中度相关');
        } else if (score >= 0.5) {
            reasons.push('语义有一定相关性');
        }
        
        // 检查关键词匹配
        const resourceText = [resource.title, resource.description].filter(Boolean).join(' ');
        const queryKeywords = this.extractKeywords(query);
        const matchedKeywords = queryKeywords.filter(keyword => resourceText.includes(keyword));
        
        if (matchedKeywords.length > 0) {
            reasons.push(`包含关键词: ${matchedKeywords.join(', ')}`);
        }
        
        // 检查实体匹配
        const resourceEntities = this.extractEntities(resourceText);
        const queryEntities = this.extractEntities(query);
        const matchedEntities = [];
        
        for (const queryEntity of queryEntities) {
            for (const resourceEntity of resourceEntities) {
                if (queryEntity.type === resourceEntity.type && 
                    (queryEntity.value === resourceEntity.value || 
                     resourceEntity.value.includes(queryEntity.value))) {
                    matchedEntities.push(`${queryEntity.type}实体匹配: ${queryEntity.value}`);
                }
            }
        }
        
        if (matchedEntities.length > 0) {
            reasons.push(...matchedEntities.slice(0, 2));
        }
        
        return reasons;
    }

    /**
     * 执行语义精准匹配
     * @param {Array} resources 资源列表
     * @param {Object} demand 需求对象
     * @param {Object} options 选项
     * @returns {Object} 语义精准匹配结果
     */
    async match(resources, demand, options = {}) {
        const startTime = Date.now();
        
        const query = demand.query || demand.title || '';
        if (!query) {
            return {
                results: [],
                total: 0,
                time: Date.now() - startTime,
                status: 'error',
                error: '缺少查询文本'
            };
        }
        
        console.log('执行语义精准匹配:', query);
        
        // 为每个资源计算语义匹配分数
        const resourcesWithScores = await Promise.all(
            resources.map(async (resource) => {
                // 构建资源的文本表示
                const resourceText = [
                    resource.title,
                    resource.description,
                    resource.category,
                    resource.tags
                ].filter(Boolean).join(' ');
                
                // 计算语义匹配分数
                const semanticScore = await this.calculateSemanticScore(query, resourceText);
                const semanticMatchReasons = this.generateSemanticMatchReasons(resource, query, semanticScore);
                
                // 存储语义向量到向量存储
                if (resource.id) {
                    const resourceEmbedding = await this.getSemanticEmbedding(resourceText);
                    await this.vectorStore.add(resource.id, resourceEmbedding.embedding, {
                        title: resource.title,
                        category: resource.category
                    });
                }
                
                return {
                    ...resource,
                    semanticScore,
                    finalMatchScore: semanticScore,
                    semanticMatchReasons
                };
            })
        );
        
        // 按语义匹配分数排序
        resourcesWithScores.sort((a, b) => b.semanticScore - a.semanticScore);
        
        // 限制返回数量
        const limitedResources = resourcesWithScores.slice(0, this.config.limit);
        
        const time = Date.now() - startTime;
        
        console.log(`语义精准匹配: 处理了 ${resources.length} 个资源，返回 ${limitedResources.length} 个结果，耗时 ${time}ms`);
        
        return {
            results: limitedResources,
            total: resourcesWithScores.length,
            time,
            status: time <= 2000 ? 'success' : 'timeout'
        };
    }

    /**
     * 批量索引资源语义向量
     * @param {Array} resources 资源列表
     * @returns {Promise<void>}
     */
    async batchIndexResources(resources) {
        console.log('批量索引资源语义向量:', resources.length);
        
        await Promise.all(
            resources.map(async (resource) => {
                if (!resource.id) return;
                
                const resourceText = [
                    resource.title,
                    resource.description,
                    resource.category,
                    resource.tags
                ].filter(Boolean).join(' ');
                
                try {
                    const resourceEmbedding = await this.getSemanticEmbedding(resourceText);
                    await this.vectorStore.add(resource.id, resourceEmbedding.embedding, {
                        title: resource.title,
                        category: resource.category
                    });
                } catch (error) {
                    console.error(`索引资源 ${resource.id} 失败:`, error);
                }
            })
        );
        
        console.log('批量索引完成');
    }

    /**
     * 清理缓存
     */
    clearCache() {
        this.cache.clear();
    }

    /**
     * 清理向量存储
     */
    async clearVectorStore() {
        if (this.vectorStore && this.vectorStore.clear) {
            await this.vectorStore.clear();
        }
    }
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = SemanticPreciseMatcher;
} else if (typeof window !== 'undefined') {
    window.SemanticPreciseMatcher = SemanticPreciseMatcher;
    window.semanticPreciseMatcher = new SemanticPreciseMatcher();
}