/**
 * 大模型语义处理与匹配系统
 * 实现基于大模型的语义理解、匹配与标准化转化统一系统
 * 通过理解用户输入的自然语言语义信息，与资源/需求的描述信息进行深度匹配
 * 并支持口语化到标准化的转化流程
 */

class SemanticProcessingSystem {
    /**
     * 构造函数
     * @param {Object} options 配置选项
     */
    constructor(options = {}) {
        // 配置选项
        this.options = {
            llmApiKey: options.llmApiKey || 'sk-f2885e8725e04ec690db459cea8bcc57',
            llmEndpoint: options.llmEndpoint || 'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
            model: options.model || 'qwen-turbo',
            maxRetries: options.maxRetries || 3,
            timeout: options.timeout || 10000,
            cacheSize: options.cacheSize || 100,
            cacheExpiry: options.cacheExpiry || 30 * 60 * 1000 // 30分钟
        };

        // 缓存管理
        this.cache = new Map();

        // 行业特定解析模板
        this.industryTemplates = {
            '家政': {
                keywords: ['家政', '保洁', '保姆', '月嫂', '育儿嫂', '钟点工'],
                fields: ['服务类型', '服务时间', '服务地点', '价格', '服务内容', '有效期']
            },
            '运输': {
                keywords: ['搬家', '货运', '运输', '快递', '物流', '配送'],
                fields: ['运输类型', '货物类型', '起始地点', '目的地', '价格', '时间要求', '有效期']
            },
            '技术服务': {
                keywords: ['编程', '设计', '开发', '维修', '技术', 'IT服务'],
                fields: ['技术类型', '服务内容', '价格', '服务时间', '服务地点', '有效期']
            }
        };

        // 初始化组件
        this.initializeComponents();
    }

    /**
     * 初始化组件
     */
    initializeComponents() {
        // 输入预处理模块
        this.inputPreprocessor = new InputPreprocessor();

        // 语义理解模块
        this.semanticAnalyzer = new SemanticAnalyzer(this.options);

        // 语义匹配模块
        this.semanticMatcher = new SemanticMatcher();

        // 标准化输出生成器
        this.standardOutputGenerator = new StandardOutputGenerator();

        // 结构化数据转换器
        this.structuredDataConverter = new StructuredDataConverter();
    }

    /**
     * 处理用户输入
     * @param {string} input 用户输入的自然语言
     * @param {Object} context 上下文信息
     * @returns {Promise<Object>} 处理结果
     */
    async processInput(input, context = {}) {
        console.log('========== 处理用户输入 ==========');
        console.log('输入:', input);
        console.log('上下文:', context);

        try {
            // 1. 输入预处理
            const preprocessedInput = this.inputPreprocessor.process(input);
            console.log('预处理结果:', preprocessedInput);

            // 2. 语义理解
            const semanticAnalysis = await this.semanticAnalyzer.analyze(preprocessedInput, context);
            console.log('语义分析结果:', semanticAnalysis);

            // 3. 标准化输出
            const standardOutput = this.standardOutputGenerator.generate(semanticAnalysis);
            console.log('标准化输出:', standardOutput);

            // 4. 结构化数据转换
            const structuredData = this.structuredDataConverter.convert(standardOutput, context);
            console.log('结构化数据:', structuredData);

            return {
                success: true,
                data: {
                    originalInput: input,
                    preprocessedInput,
                    semanticAnalysis,
                    standardOutput,
                    structuredData
                }
            };
        } catch (error) {
            console.error('处理用户输入失败:', error);
            return {
                success: false,
                error: error.message,
                data: {
                    originalInput: input
                }
            };
        }
    }

    /**
     * 执行语义匹配
     * @param {Array} resources 资源列表
     * @param {string} query 查询文本
     * @param {Object} options 匹配选项
     * @returns {Promise<Array>} 带有语义匹配分数的资源列表
     */
    async match(resources, query, options = {}) {
        console.log('========== 执行语义匹配 ==========');
        console.log('查询:', query);
        console.log('资源数量:', resources.length);
        console.log('匹配选项:', options);

        try {
            // 处理查询
            const queryProcessingResult = await this.processInput(query, {
                type: 'query'
            });

            if (!queryProcessingResult.success) {
                console.error('处理查询失败:', queryProcessingResult.error);
                // 使用降级方案
                return this.fallbackMatch(resources, query, options);
            }

            const querySemanticData = queryProcessingResult.data.semanticAnalysis;

            // 为每个资源计算语义匹配分数
            const resourcesWithSemanticScores = await Promise.all(
                resources.map(async (resource) => {
                    // 构建资源的文本表示
                    const resourceText = [
                        resource.title,
                        resource.description,
                        resource.category,
                        resource.tags
                    ].filter(Boolean).join(' ');

                    // 处理资源文本
                    const resourceProcessingResult = await this.processInput(resourceText, {
                        type: 'resource',
                        resourceId: resource.id
                    });

                    let semanticScore = 0.5;
                    let semanticMatchReasons = [];

                    if (resourceProcessingResult.success) {
                        const resourceSemanticData = resourceProcessingResult.data.semanticAnalysis;
                        // 计算语义匹配分数
                        semanticScore = this.semanticMatcher.calculateSemanticScore(
                            querySemanticData.embedding,
                            resourceSemanticData.embedding
                        );
                        // 生成匹配原因
                        semanticMatchReasons = this.generateSemanticMatchReasons(
                            resource,
                            query,
                            semanticScore,
                            querySemanticData,
                            resourceSemanticData
                        );
                    }

                    return {
                        ...resource,
                        semanticScore,
                        semanticMatchReasons,
                        semanticAnalysis: resourceProcessingResult.success ? resourceProcessingResult.data.semanticAnalysis : null
                    };
                })
            );

            // 按语义匹配分数排序
            resourcesWithSemanticScores.sort((a, b) => b.semanticScore - a.semanticScore);

            console.log('语义匹配完成，匹配结果数量:', resourcesWithSemanticScores.length);
            return resourcesWithSemanticScores;
        } catch (error) {
            console.error('执行语义匹配失败:', error);
            // 使用降级方案
            return this.fallbackMatch(resources, query, options);
        }
    }

    /**
     * 生成语义匹配原因
     * @param {Object} resource 资源对象
     * @param {string} query 查询文本
     * @param {number} score 语义匹配分数
     * @param {Object} querySemanticData 查询的语义数据
     * @param {Object} resourceSemanticData 资源的语义数据
     * @returns {Array} 语义匹配原因数组
     */
    generateSemanticMatchReasons(resource, query, score, querySemanticData, resourceSemanticData) {
        const reasons = [];

        // 基于分数生成原因
        if (score >= 0.8) {
            reasons.push('语义高度相关');
        } else if (score >= 0.6) {
            reasons.push('语义中度相关');
        } else if (score >= 0.4) {
            reasons.push('语义有一定相关性');
        }

        // 检查关键词匹配
        if (querySemanticData.keywords && resourceSemanticData.keywords) {
            const matchedKeywords = querySemanticData.keywords.filter(
                keyword => resourceSemanticData.keywords.includes(keyword)
            );
            if (matchedKeywords.length > 0) {
                reasons.push(`包含关键词: ${matchedKeywords.join(', ')}`);
            }
        }

        // 检查实体匹配
        if (querySemanticData.entities && resourceSemanticData.entities) {
            const matchedEntities = querySemanticData.entities.filter(
                queryEntity => resourceSemanticData.entities.some(
                    resourceEntity => resourceEntity.type === queryEntity.type && 
                                     resourceEntity.value === queryEntity.value
                )
            );
            if (matchedEntities.length > 0) {
                reasons.push(`包含实体: ${matchedEntities.map(e => e.value).join(', ')}`);
            }
        }

        // 检查分类匹配
        if (querySemanticData.category && resource.category) {
            if (resource.category.includes(querySemanticData.category)) {
                reasons.push(`分类匹配: ${querySemanticData.category}`);
            }
        }

        return reasons;
    }

    /**
     * 降级匹配方案
     * @param {Array} resources 资源列表
     * @param {string} query 查询文本
     * @param {Object} options 匹配选项
     * @returns {Array} 带有匹配分数的资源列表
     */
    async fallbackMatch(resources, query, options = {}) {
        console.log('使用降级匹配方案');

        try {
            // 使用简单的关键词匹配
            const keywords = this.extractKeywords(query);
            console.log('提取关键词:', keywords);

            const resourcesWithScores = resources.map(resource => {
                // 构建资源的文本表示
                const resourceText = [
                    resource.title,
                    resource.description,
                    resource.category,
                    resource.tags
                ].filter(Boolean).join(' ').toLowerCase();

                // 计算关键词匹配分数
                let keywordScore = 0;
                keywords.forEach(keyword => {
                    if (resourceText.includes(keyword.toLowerCase())) {
                        keywordScore += 1 / keywords.length;
                    }
                });

                return {
                    ...resource,
                    semanticScore: keywordScore,
                    semanticMatchReasons: keywordScore > 0 ? 
                        [`关键词匹配: ${keywords.filter(k => resourceText.includes(k.toLowerCase())).join(', ')}`] : 
                        ['使用降级匹配方案']
                };
            });

            // 按匹配分数排序
            resourcesWithScores.sort((a, b) => b.semanticScore - a.semanticScore);

            return resourcesWithScores;
        } catch (error) {
            console.error('降级匹配方案失败:', error);
            // 返回原始资源列表
            return resources;
        }
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
     * 清理缓存
     */
    clearCache() {
        this.cache.clear();
        if (this.semanticAnalyzer) {
            this.semanticAnalyzer.clearCache();
        }
    }

    /**
     * 获取缓存大小
     * @returns {number} 缓存大小
     */
    getCacheSize() {
        return this.cache.size;
    }
}

/**
 * 输入预处理模块
 * 处理用户输入的自然语言，进行清洗、规范化等操作
 */
class InputPreprocessor {
    /**
     * 处理输入文本
     * @param {string} input 输入文本
     * @returns {string} 处理后的文本
     */
    process(input) {
        if (!input || typeof input !== 'string') {
            return '';
        }

        // 1. 去除多余空格
        let processed = input.trim();

        // 2. 规范化标点符号
        processed = this.normalizePunctuation(processed);

        // 3. 去除重复字符
        processed = this.removeDuplicateCharacters(processed);

        // 4. 规范化数字格式
        processed = this.normalizeNumbers(processed);

        // 5. 增强描述内容
        processed = this.enhanceDescription(processed);

        return processed;
    }

    /**
     * 规范化标点符号
     * @param {string} text 输入文本
     * @returns {string} 规范化后的文本
     */
    normalizePunctuation(text) {
        return text
            .replace(/[。！？.!?]+/g, '。')
            .replace(/[，,]+/g, '，')
            .replace(/[；;]+/g, '；')
            .replace(/[：:]+/g, '：');
    }

    /**
     * 去除重复字符
     * @param {string} text 输入文本
     * @returns {string} 处理后的文本
     */
    removeDuplicateCharacters(text) {
        return text.replace(/(.)\1{2,}/g, '$1');
    }

    /**
     * 规范化数字格式
     * @param {string} text 输入文本
     * @returns {string} 规范化后的文本
     */
    normalizeNumbers(text) {
        // 替换中文数字为阿拉伯数字
        const chineseNumbers = {
            '零': 0, '一': 1, '二': 2, '三': 3, '四': 4,
            '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
            '十': 10, '百': 100, '千': 1000, '万': 10000
        };

        let normalized = text;
        for (const [chinese, arabic] of Object.entries(chineseNumbers)) {
            normalized = normalized.replace(new RegExp(chinese, 'g'), arabic.toString());
        }

        return normalized;
    }

    /**
     * 增强描述内容
     * @param {string} text 输入文本
     * @returns {string} 增强后的文本
     */
    enhanceDescription(text) {
        let enhanced = text.trim();

        // 确保描述以适当的标点符号结尾
        if (!/[。！？.!?]$/.test(enhanced)) {
            enhanced += '。';
        }

        return enhanced;
    }
}

/**
 * 语义分析模块
 * 集成大模型进行语义理解和分析
 */
class SemanticAnalyzer {
    /**
     * 构造函数
     * @param {Object} config 配置选项
     */
    constructor(config) {
        this.config = config;
        this.cache = new Map();
    }

    /**
     * 分析文本语义
     * @param {string} text 输入文本
     * @param {Object} context 上下文信息
     * @returns {Promise<Object>} 语义分析结果
     */
    async analyze(text, context = {}) {
        console.log('分析文本语义:', text);

        // 检查缓存
        const cacheKey = this.generateCacheKey(text, context);
        if (this.cache.has(cacheKey)) {
            const cached = this.cache.get(cacheKey);
            if (Date.now() < cached.expiry) {
                console.log('使用缓存的语义分析结果');
                return cached.data;
            }
            // 清除过期缓存
            this.cache.delete(cacheKey);
        }

        try {
            // 调用大模型进行语义分析
            const analysisResult = await this.callLLMForAnalysis(text, context);
            console.log('大模型语义分析结果:', analysisResult);

            // 缓存结果
            this.cacheResult(cacheKey, analysisResult);

            return analysisResult;
        } catch (error) {
            console.error('语义分析失败:', error);
            // 使用降级方案
            return this.fallbackAnalysis(text, context);
        }
    }

    /**
     * 调用大模型进行语义分析
     * @param {string} text 输入文本
     * @param {Object} context 上下文信息
     * @returns {Promise<Object>} 语义分析结果
     */
    async callLLMForAnalysis(text, context = {}) {
        // 构建提示词
        const prompt = this.buildAnalysisPrompt(text, context);
        console.log('构建提示词:', prompt);

        // 准备API请求参数
        const requestData = {
            model: this.config.model,
            messages: [
                {
                    role: 'system',
                    content: '你是一个智能语义分析助手，专门用于分析用户输入的文本，提取语义信息。'
                },
                {
                    role: 'user',
                    content: prompt
                }
            ],
            temperature: 0.3,
            max_tokens: 1000
        };

        // 发送API请求
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), this.config.timeout);

        try {
            const response = await fetch(this.config.llmEndpoint, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${this.config.llmApiKey}`
                },
                body: JSON.stringify(requestData),
                signal: controller.signal
            });

            clearTimeout(timeoutId);

            if (!response.ok) {
                throw new Error(`API错误: ${response.status} ${response.statusText}`);
            }

            const data = await response.json();
            console.log('API响应:', data);

            // 提取并解析大模型的回答
            const assistantMessage = data.choices?.[0]?.message?.content;
            if (!assistantMessage) {
                throw new Error('大模型返回格式错误');
            }

            // 解析JSON响应
            try {
                const parsedResult = JSON.parse(assistantMessage);
                return this.validateAndFormatAnalysisResult(parsedResult, text, context);
            } catch (parseError) {
                console.error('解析大模型响应失败:', parseError);
                throw new Error('大模型返回的不是有效的JSON格式');
            }
        } catch (error) {
            clearTimeout(timeoutId);
            console.error('API请求错误:', error);

            // 处理特定错误
            if (error.name === 'AbortError') {
                throw new Error('API请求超时，请检查网络连接');
            } else if (error.message.includes('Failed to fetch')) {
                throw new Error('网络连接失败，请检查网络设置');
            }

            throw error;
        }
    }

    /**
     * 构建分析提示词
     * @param {string} text 输入文本
     * @param {Object} context 上下文信息
     * @returns {string} 提示词
     */
    buildAnalysisPrompt(text, context = {}) {
        return `请分析以下文本的语义信息，并以JSON格式返回分析结果。\n\n` +
            `【文本】\n${text}\n\n` +
            `【上下文】\n${JSON.stringify(context)}\n\n` +
            `【需要提取的语义信息】\n` +
            `- embedding: 语义向量嵌入（长度为100的数组）\n` +
            `- keywords: 核心关键词数组\n` +
            `- entities: 实体数组，每个实体包含type和value字段\n` +
            `- category: 预测的分类\n` +
            `- intent: 用户意图\n` +
            `- sentiment: 情绪倾向（positive/neutral/negative）\n` +
            `- confidence: 置信度（0-1之间的数字）\n` +
            `- industry: 所属行业\n` +
            `- timeRequirement: 时间要求\n` +
            `- location: 地点信息\n\n` +
            `【注意事项】\n` +
            `1. 严格按照JSON格式返回，不要包含任何额外文本\n` +
            `2. 确保所有字段都有合理的值，对于无法提取的字段返回null\n` +
            `3. 语义向量嵌入应是长度为100的数字数组\n` +
            `4. 关键词应去除停用词，只保留核心词汇\n\n` +
            `【示例输出】\n` +
            `{\n` +
            `  "embedding": [0.1, 0.2, 0.3, ...],\n` +
            `  "keywords": ["水管", "维修", "上门"],\n` +
            `  "entities": [{"type": "item", "value": "水管"}, {"type": "service", "value": "维修"}],\n` +
            `  "category": "skill",\n` +
            `  "intent": "search",\n` +
            `  "sentiment": "neutral",\n` +
            `  "confidence": 0.95,\n` +
            `  "industry": "技术服务",\n` +
            `  "timeRequirement": "今天",\n` +
            `  "location": "北京市朝阳区"\n` +
            `}`;
    }

    /**
     * 验证和格式化分析结果
     * @param {Object} result 分析结果
     * @param {string} text 输入文本
     * @param {Object} context 上下文信息
     * @returns {Object} 验证和格式化后的结果
     */
    validateAndFormatAnalysisResult(result, text, context = {}) {
        // 确保所有必要字段都存在
        const requiredFields = [
            'embedding', 'keywords', 'entities', 'category',
            'intent', 'sentiment', 'confidence', 'industry',
            'timeRequirement', 'location'
        ];

        for (const field of requiredFields) {
            if (result[field] === undefined) {
                result[field] = null;
            }
        }

        // 确保语义向量嵌入是有效的数组
        if (!result.embedding || !Array.isArray(result.embedding) || result.embedding.length !== 100) {
            result.embedding = this.generateMockEmbedding(text);
        }

        // 确保关键词是数组
        if (!Array.isArray(result.keywords)) {
            result.keywords = this.extractKeywords(text);
        }

        // 确保实体是数组
        if (!Array.isArray(result.entities)) {
            result.entities = [];
        }

        // 确保置信度是有效的数字
        if (typeof result.confidence !== 'number' || result.confidence < 0 || result.confidence > 1) {
            result.confidence = 0.8;
        }

        return result;
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
     * 降级分析方案
     * @param {string} text 输入文本
     * @param {Object} context 上下文信息
     * @returns {Object} 分析结果
     */
    fallbackAnalysis(text, context = {}) {
        console.log('使用降级分析方案');

        return {
            embedding: this.generateMockEmbedding(text),
            keywords: this.extractKeywords(text),
            entities: this.identifyEntities(text),
            category: this.predictCategory(text),
            intent: this.detectIntent(text),
            sentiment: 'neutral',
            confidence: 0.7,
            industry: this.identifyIndustry(text),
            timeRequirement: this.extractTimeRequirement(text),
            location: this.extractLocation(text)
        };
    }

    /**
     * 识别实体
     * @param {string} text 输入文本
     * @returns {Array} 识别的实体数组
     */
    identifyEntities(text) {
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

        // 提取服务实体
        const servicePatterns = [/维修|保洁|搬家|运输|配送|安装|调试|培训|咨询/];
        for (const pattern of servicePatterns) {
            const matches = text.match(pattern);
            if (matches) {
                entities.push({
                    type: 'service',
                    value: matches[0]
                });
            }
        }

        // 提取物品实体
        const itemPatterns = [/水管|水龙头|电器|家具|工具|梯子|车辆/];
        for (const pattern of itemPatterns) {
            const matches = text.match(pattern);
            if (matches) {
                entities.push({
                    type: 'item',
                    value: matches[0]
                });
            }
        }

        return entities;
    }

    /**
     * 预测分类
     * @param {string} text 输入文本
     * @returns {string} 预测的分类
     */
    predictCategory(text) {
        if (text.includes('人') || text.includes('兼职') || text.includes('全职') || text.includes('服务')) {
            return 'person';
        }
        if (text.includes('车') || text.includes('网约车') || text.includes('租车') || text.includes('运输')) {
            return 'car';
        }
        if (text.includes('技能') || text.includes('服务') || text.includes('维修') || text.includes('技术')) {
            return 'skill';
        }
        if (text.includes('物') || text.includes('工具') || text.includes('梯子') || text.includes('租赁') || text.includes('出售')) {
            return 'thing';
        }
        return 'all';
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
     * 识别行业
     * @param {string} text 输入文本
     * @returns {string} 识别的行业
     */
    identifyIndustry(text) {
        const industries = {
            '家政': ['家政', '保洁', '保姆', '月嫂', '育儿嫂', '钟点工'],
            '运输': ['搬家', '货运', '运输', '快递', '物流', '配送'],
            '技术服务': ['编程', '设计', '开发', '维修', '技术', 'IT服务'],
            '教育培训': ['培训', '教育', '学习', '课程', '辅导'],
            '健康医疗': ['医疗', '健康', '保健', '养生', '体检'],
            '餐饮服务': ['餐饮', '美食', '外卖', '餐厅', '厨师']
        };

        for (const [industry, keywords] of Object.entries(industries)) {
            for (const keyword of keywords) {
                if (text.includes(keyword)) {
                    return industry;
                }
            }
        }

        return '通用';
    }

    /**
     * 提取时间要求
     * @param {string} text 输入文本
     * @returns {string} 提取的时间要求
     */
    extractTimeRequirement(text) {
        const timePatterns = [/今天|明天|后天|本周|下周|本月|下月|(\d+)月(\d+)日|(\d+)点(\d+)?分|紧急|尽快/];
        for (const pattern of timePatterns) {
            const matches = text.match(pattern);
            if (matches) {
                return matches[0];
            }
        }
        return null;
    }

    /**
     * 提取地点信息
     * @param {string} text 输入文本
     * @returns {string} 提取的地点信息
     */
    extractLocation(text) {
        const locationPatterns = [/在(.+?)附近/, /(北京|上海|广州|深圳|杭州|成都|武汉|西安)\s*的?/, /(朝阳区|海淀区|东城区|西城区|丰台区|石景山区|门头沟区|房山区|通州区|顺义区|昌平区|大兴区|怀柔区|平谷区|密云区|延庆区)/];
        for (const pattern of locationPatterns) {
            const matches = text.match(pattern);
            if (matches) {
                return matches[1] || matches[0];
            }
        }
        return null;
    }

    /**
     * 生成缓存键
     * @param {string} text 输入文本
     * @param {Object} context 上下文信息
     * @returns {string} 缓存键
     */
    generateCacheKey(text, context = {}) {
        return `semantic_${btoa(unescape(encodeURIComponent(text + JSON.stringify(context))))}`;
    }

    /**
     * 缓存结果
     * @param {string} key 缓存键
     * @param {Object} data 缓存数据
     */
    cacheResult(key, data) {
        this.cache.set(key, {
            data,
            expiry: Date.now() + this.config.cacheExpiry
        });

        // 限制缓存大小
        if (this.cache.size > this.config.cacheSize) {
            const oldestKey = this.cache.keys().next().value;
            this.cache.delete(oldestKey);
        }
    }

    /**
     * 清理缓存
     */
    clearCache() {
        this.cache.clear();
    }
}

/**
 * 标准化输出生成器
 * 生成标准化的输出格式
 */
class StandardOutputGenerator {
    /**
     * 生成标准化输出
     * @param {Object} semanticAnalysis 语义分析结果
     * @returns {Object} 标准化输出
     */
    generate(semanticAnalysis) {
        if (!semanticAnalysis) {
            return {};
        }

        return {
            // 基本信息
            input: semanticAnalysis.input || '',
            confidence: semanticAnalysis.confidence || 0.5,
            timestamp: new Date().toISOString(),

            // 语义信息
            semantic: {
                keywords: semanticAnalysis.keywords || [],
                entities: semanticAnalysis.entities || [],
                category: semanticAnalysis.category || 'all',
                intent: semanticAnalysis.intent || 'search',
                sentiment: semanticAnalysis.sentiment || 'neutral',
                industry: semanticAnalysis.industry || '通用'
            },

            // 上下文信息
            context: {
                timeRequirement: semanticAnalysis.timeRequirement || null,
                location: semanticAnalysis.location || null,
                embedding: semanticAnalysis.embedding || []
            }
        };
    }
}

/**
 * 结构化数据转换器
 * 将语义分析结果转换为结构化数据
 */
class StructuredDataConverter {
    /**
     * 转换为结构化数据
     * @param {Object} standardOutput 标准化输出
     * @param {Object} context 上下文信息
     * @returns {Object} 结构化数据
     */
    convert(standardOutput, context = {}) {
        if (!standardOutput) {
            return {};
        }

        // 根据不同的类型生成不同的结构化数据
        switch (context.type) {
            case 'query':
                return this.convertToQueryStructure(standardOutput, context);
            case 'resource':
                return this.convertToResourceStructure(standardOutput, context);
            case 'demand':
                return this.convertToDemandStructure(standardOutput, context);
            default:
                return this.convertToGeneralStructure(standardOutput, context);
        }
    }

    /**
     * 转换为查询结构化数据
     * @param {Object} standardOutput 标准化输出
     * @param {Object} context 上下文信息
     * @returns {Object} 查询结构化数据
     */
    convertToQueryStructure(standardOutput, context = {}) {
        return {
            type: 'query',
            keywords: standardOutput.semantic?.keywords || [],
            category: standardOutput.semantic?.category || 'all',
            intent: standardOutput.semantic?.intent || 'search',
            industry: standardOutput.semantic?.industry || '通用',
            timeRequirement: standardOutput.context?.timeRequirement || null,
            location: standardOutput.context?.location || null,
            confidence: standardOutput.confidence || 0.5,
            timestamp: standardOutput.timestamp || new Date().toISOString()
        };
    }

    /**
     * 转换为资源结构化数据
     * @param {Object} standardOutput 标准化输出
     * @param {Object} context 上下文信息
     * @returns {Object} 资源结构化数据
     */
    convertToResourceStructure(standardOutput, context = {}) {
        return {
            type: 'resource',
            resourceId: context.resourceId || null,
            keywords: standardOutput.semantic?.keywords || [],
            category: standardOutput.semantic?.category || 'all',
            industry: standardOutput.semantic?.industry || '通用',
            timeRequirement: standardOutput.context?.timeRequirement || null,
            location: standardOutput.context?.location || null,
            embedding: standardOutput.context?.embedding || [],
            confidence: standardOutput.confidence || 0.5,
            timestamp: standardOutput.timestamp || new Date().toISOString()
        };
    }

    /**
     * 转换为需求结构化数据
     * @param {Object} standardOutput 标准化输出
     * @param {Object} context 上下文信息
     * @returns {Object} 需求结构化数据
     */
    convertToDemandStructure(standardOutput, context = {}) {
        return {
            type: 'demand',
            demandId: context.demandId || null,
            keywords: standardOutput.semantic?.keywords || [],
            category: standardOutput.semantic?.category || 'all',
            industry: standardOutput.semantic?.industry || '通用',
            timeRequirement: standardOutput.context?.timeRequirement || null,
            location: standardOutput.context?.location || null,
            embedding: standardOutput.context?.embedding || [],
            confidence: standardOutput.confidence || 0.5,
            timestamp: standardOutput.timestamp || new Date().toISOString()
        };
    }

    /**
     * 转换为通用结构化数据
     * @param {Object} standardOutput 标准化输出
     * @param {Object} context 上下文信息
     * @returns {Object} 通用结构化数据
     */
    convertToGeneralStructure(standardOutput, context = {}) {
        return {
            type: 'general',
            keywords: standardOutput.semantic?.keywords || [],
            category: standardOutput.semantic?.category || 'all',
            intent: standardOutput.semantic?.intent || 'search',
            industry: standardOutput.semantic?.industry || '通用',
            timeRequirement: standardOutput.context?.timeRequirement || null,
            location: standardOutput.context?.location || null,
            confidence: standardOutput.confidence || 0.5,
            timestamp: standardOutput.timestamp || new Date().toISOString()
        };
    }
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = SemanticProcessingSystem;
    module.exports.InputPreprocessor = InputPreprocessor;
    module.exports.SemanticAnalyzer = SemanticAnalyzer;
    module.exports.StandardOutputGenerator = StandardOutputGenerator;
    module.exports.StructuredDataConverter = StructuredDataConverter;
} else if (typeof window !== 'undefined') {
    window.SemanticProcessingSystem = SemanticProcessingSystem;
    window.semanticProcessingSystem = new SemanticProcessingSystem();
}
