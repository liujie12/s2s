/**
 * 防抖函数
 * @param {Function} func - 要执行的函数
 * @param {number} wait - 等待时间（毫秒）
 * @returns {Function} 防抖处理后的函数
 */
function debounce(func, wait) {
    let timeout;
    return function executedFunction(...args) {
        const later = () => {
            clearTimeout(timeout);
            func(...args);
        };
        clearTimeout(timeout);
        timeout = setTimeout(later, wait);
    };
}

/**
 * 节流函数
 * @param {Function} func - 要执行的函数
 * @param {number} limit - 时间限制（毫秒）
 * @returns {Function} 节流处理后的函数
 */
function throttle(func, limit) {
    let inThrottle;
    return function executedFunction(...args) {
        if (!inThrottle) {
            func.apply(this, args);
            inThrottle = true;
            setTimeout(() => inThrottle = false, limit);
        }
    };
}

// 搜索条件存储
let searchConditions = {
    keyword: '',
    category: 'all',
    maxDistance: 50,
    minRating: 0,
    priceRange: { min: 0, max: 999999 }
};

// 实时搜索处理函数（带防抖）
const handleRealTimeSearch = debounce((event) => {
    console.log('========== 实时搜索处理 ==========');
    console.log('事件:', event);
    console.log('目标:', event.target);
    const keyword = event.target.value.trim().toLowerCase();
    console.log('搜索关键词:', keyword);
    searchConditions.keyword = keyword;
    console.log('搜索条件:', searchConditions);
    performSearch(searchConditions);
}, 300); // 300毫秒防抖

// 千问大模型集成配置
const QIANWEN_CONFIG = {
    API_KEY: 'sk-f2885e8725e04ec690db459cea8bcc57', // 用户提供的API密钥
    API_ENDPOINT: 'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
    MODEL: 'qwen-turbo', // 使用千问Turbo模型，性价比高
    MAX_RETRIES: 3,
    CACHE_EXPIRY: 30 * 60 * 1000, // 30分钟缓存
    TIMEOUT: 10000 // 10秒超时
};

// 缓存管理
const llmCache = new Map();

// 生成缓存键
function generateCacheKey(prompt) {
    return `llm_${btoa(unescape(encodeURIComponent(prompt)))}`;
}

// 从缓存获取结果
function getFromCache(prompt) {
    const key = generateCacheKey(prompt);
    const cached = llmCache.get(key);
    if (cached && Date.now() < cached.expiry) {
        console.log('从缓存获取大模型结果');
        return cached.data;
    }
    // 清除过期缓存
    if (cached && Date.now() >= cached.expiry) {
        llmCache.delete(key);
    }
    return null;
}

// 保存到缓存
function saveToCache(prompt, data) {
    const key = generateCacheKey(prompt);
    llmCache.set(key, {
        data,
        expiry: Date.now() + QIANWEN_CONFIG.CACHE_EXPIRY
    });
    // 限制缓存大小
    if (llmCache.size > 100) {
        const oldestKey = llmCache.keys().next().value;
        llmCache.delete(oldestKey);
    }
}

// 构建千问大模型提示词
function buildQianwenPrompt(prompt) {
    return `你是一个智能搜索助手，负责理解用户的搜索意图并提取关键信息。

请分析以下搜索查询，按照要求输出结果：

搜索查询：${prompt}

输出要求：
1. 提取核心关键词（去除停用词）
2. 识别实体（如工具、服务、物品等）
3. 预测最可能的资源分类（person/car/skill/item）
4. 识别用户意图（搜索资源还是发布需求）
5. 分析情绪倾向（positive/neutral/negative）
6. 给出置信度（0-1之间的数字）

请以JSON格式输出，字段名如下：
- keywords: 关键词数组
- entities: 实体数组，每个实体包含type和value字段
- category: 预测的分类
- intent: 用户意图（search/demand）
- sentiment: 情绪倾向
- confidence: 置信度

示例输出：
{
  "keywords": ["水管", "维修"],
  "entities": [{"type": "item", "value": "水管"}, {"type": "service", "value": "维修"}],
  "category": "skill",
  "intent": "search",
  "sentiment": "neutral",
  "confidence": 0.95
}`;
}

// 调用千问大模型API
async function callQianwenAPI(prompt, retryCount = 0) {
    try {
        console.log('调用千问大模型API:', prompt);
        
        const response = await fetch(QIANWEN_CONFIG.API_ENDPOINT, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${QIANWEN_CONFIG.API_KEY}`
            },
            body: JSON.stringify({
                model: QIANWEN_CONFIG.MODEL,
                messages: [
                    {
                        role: 'system',
                        content: '你是一个智能搜索助手，负责理解用户的搜索意图并提取关键信息。'
                    },
                    {
                        role: 'user',
                        content: buildQianwenPrompt(prompt)
                    }
                ],
                temperature: 0.3,
                max_tokens: 500
            }),
            timeout: QIANWEN_CONFIG.TIMEOUT
        });
        
        if (!response.ok) {
            throw new Error(`API错误: ${response.status} ${response.statusText}`);
        }
        
        const data = await response.json();
        console.log('千问大模型API响应:', data);
        
        // 提取并解析千问大模型的回答
        const assistantMessage = data.choices?.[0]?.message?.content;
        if (!assistantMessage) {
            throw new Error('千问大模型返回格式错误');
        }
        
        // 解析JSON响应
        try {
            const parsedResult = JSON.parse(assistantMessage);
            return parsedResult;
        } catch (parseError) {
            console.error('解析千问大模型响应失败:', parseError);
            console.error('原始响应:', assistantMessage);
            throw new Error('解析千问大模型响应失败');
        }
        
    } catch (error) {
        console.error('千问大模型API调用失败:', error);
        
        // 重试机制
        if (retryCount < QIANWEN_CONFIG.MAX_RETRIES) {
            const delay = Math.pow(2, retryCount) * 1000; // 指数退避
            console.log(`重试调用千问大模型API (${retryCount + 1}/${QIANWEN_CONFIG.MAX_RETRIES})，延迟 ${delay}ms`);
            await new Promise(resolve => setTimeout(resolve, delay));
            return callQianwenAPI(prompt, retryCount + 1);
        }
        
        // 重试失败，抛出错误
        throw error;
    }
}

// 大模型自然语言处理接口集成
async function callLLMService(prompt) {
    console.log('调用大模型服务:', prompt);
    
    // 检查缓存
    const cachedResult = getFromCache(prompt);
    if (cachedResult) {
        return cachedResult;
    }
    
    try {
        // 调用千问大模型API
        const result = await callQianwenAPI(prompt);
        console.log('千问大模型解析结果:', result);
        
        // 保存到缓存
        saveToCache(prompt, result);
        
        return result;
    } catch (error) {
        console.error('大模型服务调用失败，使用降级方案:', error);
        
        // 降级方案：使用传统的关键词提取和分类逻辑
        const fallbackResult = {
            intent: 'search',
            keywords: extractKeywords(prompt),
            entities: identifyEntities(prompt),
            category: predictCategory(prompt),
            sentiment: 'positive',
            confidence: 0.8
        };
        console.log('降级方案结果:', fallbackResult);
        
        // 保存降级结果到缓存
        saveToCache(prompt, fallbackResult);
        
        return fallbackResult;
    }
}

// 提取关键词
function extractKeywords(text) {
    const stopWords = ['的', '了', '是', '在', '有', '和', '就', '不', '人', '都', '一', '一个', '上', '也', '很', '到', '说', '去', '你', '会', '着', '没有', '看', '好', '自己', '这'];
    return text.toLowerCase().split(/[\s，,]+/)
        .filter(word => word.length > 1 && !stopWords.includes(word));
}

// 识别实体
function identifyEntities(text) {
    const entities = [];
    if (text.includes('梯子') || text.includes('工具')) {
        entities.push({ type: 'tool', value: text.includes('梯子') ? '梯子' : '工具' });
    }
    if (text.includes('维修') || text.includes('修')) {
        entities.push({ type: 'service', value: '维修' });
    }
    if (text.includes('水') || text.includes('龙头') || text.includes('水管')) {
        entities.push({ type: 'item', value: '水龙头' });
    }
    return entities;
}

// 预测分类
function predictCategory(text) {
    if (text.includes('人') || text.includes('兼职') || text.includes('全职')) {
        return 'person';
    }
    if (text.includes('车') || text.includes('网约车') || text.includes('租车')) {
        return 'car';
    }
    if (text.includes('技能') || text.includes('服务') || text.includes('维修')) {
        return 'skill';
    }
    if (text.includes('物') || text.includes('工具') || text.includes('梯子') || text.includes('租赁')) {
        return 'thing';
    }
    return 'all';
}

// 执行搜索
async function performSearch(conditions) {
    console.log('========== 执行搜索 ==========');
    console.log('搜索条件:', conditions);
    console.log('搜索关键词:', conditions.keyword);
    console.log('搜索分类:', conditions.category);
    console.log('搜索距离:', conditions.maxDistance);
    console.log('搜索评分:', conditions.minRating);
    console.log('搜索价格范围:', conditions.priceRange);
    
    // 显示加载状态
    showLoading();
    
    const { keyword, category, maxDistance, minRating, priceRange } = conditions;
    
    // 如果搜索关键词为空，显示所有资源和需求
    if (!keyword) {
        // 清空筛选条件，显示所有资源
        showCategoryList(currentCategory);
        // 重新添加所有标记
        addMarkers();
        return;
    }
    
    // 调用语义处理系统进行智能解析
    let semanticResult = null;
    let llmResult = null;
    try {
        // 确保语义处理系统已加载
        if (typeof semanticProcessingSystem !== 'undefined') {
            semanticResult = await semanticProcessingSystem.processInput(keyword, {
                type: 'query'
            });
            console.log('语义处理系统结果:', semanticResult);
        } else {
            // 降级使用传统大模型服务
            console.log('语义处理系统未加载，使用传统大模型服务');
            llmResult = await callLLMService(keyword);
        }
    } catch (error) {
        console.error('语义处理失败:', error);
        // 失败时继续使用传统搜索逻辑
    }
    
    // 遍历所有分类，收集匹配的资源和需求
    const matchingResources = [];
    
    // 获取分类（如果指定了分类，或使用语义处理预测的分类）
    let predictedCategory = 'all';
    if (semanticResult && semanticResult.success) {
        predictedCategory = semanticResult.data.structuredData.category || 'all';
    } else if (llmResult) {
        predictedCategory = llmResult.category || 'all';
    }
    
    const categories = (category === 'all' && predictedCategory !== 'all') ? 
        [predictedCategory] : 
        (category === 'all' ? Object.keys(categoryData).filter(cat => cat !== 'all') : [category]);
    console.log('使用分类：', categories);
    
    // 提取搜索关键词中的核心词汇
    const keywords = keyword.toLowerCase().split(/[\s，]+/).filter(word => word.length > 0);
    console.log('原始关键词：', keywords);
    
    // 停用词列表，不包括需求关键词
    const stopWords = ['的', '了', '是', '在', '有', '和', '就', '不', '人', '都', '一', '一个', '上', '也', '很', '到', '说', '去', '你', '会', '着', '没有', '看', '好', '自己', '这', '最便宜', '最', '便宜'];
    
    // 使用语义处理系统提取的关键词或传统方法提取的关键词
    let coreKeywords = keywords.filter(word => !stopWords.includes(word));
    if (semanticResult && semanticResult.success) {
        coreKeywords = semanticResult.data.semanticAnalysis.keywords || coreKeywords;
    } else if (llmResult) {
        coreKeywords = llmResult.keywords || coreKeywords;
    }
    console.log('核心关键词：', coreKeywords);
    
    // 确定搜索的核心需求类型
    const isWaterRepair = keyword.includes('水') || keyword.includes('龙头') || keyword.includes('水管');
    const isRepairNeeded = keyword.includes('维修') || keyword.includes('修');
    const isToolSearch = keyword.includes('工具') || keyword.includes('梯子') || keyword.includes('借用');
    
    // 扩展水管相关搜索的判断，确保单独输入"水管"也能匹配到相关维修资源
    const isPlumbingRelated = isWaterRepair || keyword.includes('管道') || keyword.includes('水暖');
    const isMaintenanceRelated = isRepairNeeded || keyword.includes('维护') || keyword.includes('保养');
    
    // 中文语义理解：判断用户意图是寻找资源还是发布需求
    const demandKeywords = ['找', '寻找', '求', '需要', '想要', '急需', '请求', '申请'];
    const resourceKeywords = ['最便宜', '价格', '服务', '提供', '专业', '上门', '附近', '推荐'];
    
    // 判断用户意图
    const isDemandIntent = demandKeywords.some(demandKey => keyword.includes(demandKey));
    const isResourceIntent = resourceKeywords.some(resourceKey => keyword.includes(resourceKey)) || 
                           (keyword.includes('最') && !isDemandIntent);
    
    // 对于"最便宜的水龙头维修"这样的输入，默认认为是寻找资源
    const shouldFilterDemands = isResourceIntent || keyword.includes('最便宜');
    console.log('用户意图分析：', { keyword, isDemandIntent, isResourceIntent, shouldFilterDemands });

    
    categories.forEach(category => {
        const data = categoryData[category];
        if (data && data.resources) {
            data.resources.forEach((resource, index) => {
                // 检查标题是否包含搜索关键词
                const resourceTitle = resource.title ? resource.title.toLowerCase() : '';
                const resourceDesc = resource.description ? resource.description.toLowerCase() : '';
                
                // 检查是否匹配完整关键词
                const fullMatch = resourceTitle.includes(keyword) || resourceDesc.includes(keyword);
                
                // 检查是否匹配核心关键词
                const coreMatch = coreKeywords.some(coreWord => 
                    resourceTitle.includes(coreWord) || resourceDesc.includes(coreWord)
                );
                
                // 对于维修相关的资源，进行更精确的处理
                const isRepairRelated = resourceTitle.includes('维修') || resourceDesc.includes('维修');
                const isResourceWaterRelated = resourceTitle.includes('水') || resourceTitle.includes('龙头') || resourceTitle.includes('水管') || 
                                             resourceDesc.includes('水') || resourceDesc.includes('龙头') || resourceDesc.includes('水管');
                const isToolRelated = resourceTitle.includes('工具') || resourceTitle.includes('梯子') || resourceTitle.includes('借用') ||
                                    resourceDesc.includes('工具') || resourceDesc.includes('梯子') || resourceDesc.includes('借用');
                const isComputerRelated = resourceTitle.includes('电脑') || resourceDesc.includes('电脑');
                
                // 对于水龙头维修和工具搜索的特殊处理
                let isMatch = false;
                
                if (fullMatch) {
                    isMatch = true;
                } else if (coreMatch) {
                    // 如果是水管相关需求，需要确保资源也与维修相关，并且排除不相关的资源
                    // 但如果是工具搜索，则不应用此特殊处理
                    if (isPlumbingRelated && !isToolRelated && !isToolSearch) {
                        isMatch = isRepairRelated && (isResourceWaterRelated || 
                                                     resourceTitle.includes('家电') || // 家电维修可能包含水管维修
                                                     resourceDesc.includes('家电')) &&
                                !isComputerRelated;
                    } else if (isToolSearch) {
                        // 如果是工具搜索，需要确保资源也与工具相关
                        isMatch = isToolRelated;
                    } else {
                        isMatch = true;
                    }
                } else if (isRepairRelated && isPlumbingRelated && !isToolRelated && !isToolSearch) {
                    // 对于维修相关的资源，只要用户搜索与水管相关，即使没有明确输入维修关键词也应匹配，并且排除不相关的资源
                    // 但如果是工具搜索，则不应用此特殊处理
                    isMatch = !isComputerRelated;
                } else if (isToolSearch) {
                    // 对于工具搜索，即使没有完全匹配核心关键词，只要资源与工具相关也应匹配
                    isMatch = isToolRelated;
                }
                
                // 额外处理：当用户单独输入"水管"时，应匹配到维修相关资源
                if (!isMatch && isPlumbingRelated && !isToolSearch) {
                    isMatch = isRepairRelated && !isComputerRelated;
                }
                
                // 检查是否需要过滤需求类资源
                const isDemandResource = resource.type === 'demand';
                const shouldInclude = !isDemandResource || !shouldFilterDemands;
                
                // 应用其他筛选条件
                if (isMatch && shouldInclude) {
                    // 检查评分筛选
                    const rating = parseFloat(resource.rating) || 0;
                    if (rating < minRating) {
                        return;
                    }
                    
                    // 检查价格范围筛选
                    const price = parseFloat(resource.price) || 0;
                    if (price < priceRange.min || price > priceRange.max) {
                        return;
                    }
                    
                    matchingResources.push({
                        category,
                        index,
                        ...resource
                    });
                }
            });
        }
    });
    
    // 使用多维度匹配算法排序
    let sortedResources = matchingResources;
    if (typeof matchingAlgorithm !== 'undefined' && matchingResources.length > 0) {
        // 创建模拟需求对象
        const demand = {
            title: keyword,
            category: currentCategory,
            budget: 100, // 模拟预算
            requiredTime: '今天', // 模拟时间需求
            coordinates: [116.397428, 39.90923] // 模拟用户位置
        };
        
        // 执行多维度匹配（异步）
        try {
            sortedResources = await matchingAlgorithm.match(matchingResources, demand, {
                maxDistance: maxDistance,
                categoryTree: {
                    person: ['兼职', '全职', '临时工', '志愿者'],
                    car: ['网约车', '货运车', '私家车', '租车'],
                    skill: ['技术', '服务', '教育', '创意'],
                    thing: ['租赁', '转让', '共享', '交换']
                }
            });
        } catch (error) {
            console.error('匹配算法执行失败:', error);
            // 失败时使用原始资源列表
        }
        
        // 使用语义处理系统进行语义匹配
        try {
            if (typeof semanticProcessingSystem !== 'undefined' && sortedResources.length > 0) {
                console.log('使用语义处理系统进行语义匹配');
                sortedResources = await semanticProcessingSystem.match(sortedResources, keyword, {
                    maxDistance: maxDistance
                });
            }
        } catch (error) {
            console.error('语义匹配失败:', error);
            // 失败时使用原始排序结果
        }
        
        // 记录搜索行为
        if (typeof personalizationService !== 'undefined') {
            // 模拟用户ID，实际应用中应该使用真实用户ID
            const userId = 'user_' + new Date().getTime();
            personalizationService.recordUserBehavior(userId, {
                type: 'search',
                keyword: keyword,
                category: currentCategory,
                timestamp: new Date().getTime()
            });
        }
        
        // 应用个性化排序
        if (typeof personalizationService !== 'undefined') {
            // 模拟用户ID，实际应用中应该使用真实用户ID
            const userId = 'user_' + new Date().getTime();
            sortedResources = personalizationService.personalizeResourceList(userId, sortedResources);
        }
        
        // 如果搜索关键词包含"最便宜"，则优先按价格排序
        if (keyword.includes('最便宜') || keyword.includes('最') && keyword.includes('便宜')) {
            sortedResources.sort((a, b) => {
                // 解析价格
                const parsePrice = (priceStr) => {
                    if (!priceStr) return 0;
                    const match = priceStr.match(/\d+(\.\d+)?/);
                    return match ? parseFloat(match[0]) : 0;
                };
                
                const priceA = parsePrice(a.price);
                const priceB = parsePrice(b.price);
                
                // 优先按价格排序
                if (priceA !== priceB) {
                    return priceA - priceB;
                }
                
                // 价格相同，按综合匹配分数排序
                if (a.finalMatchScore && b.finalMatchScore) {
                    return b.finalMatchScore - a.finalMatchScore;
                }
                
                // 没有综合匹配分数，按语义匹配分数排序
                if (a.semanticScore && b.semanticScore) {
                    return b.semanticScore - a.semanticScore;
                }
                
                // 没有语义匹配分数，按原始匹配分数排序
                if (a.matchScore && b.matchScore) {
                    return b.matchScore - a.matchScore;
                }
                
                return 0;
            });
        }
    }
    
    // 清空地图标记
    clearMarkers();
    
    // 在地图上显示匹配的标记
        if (map && mapLoaded) {
            // 真实地图API的处理
            sortedResources.forEach((resource, mapIndex) => {
                // 为了演示，使用模拟位置
                const basePos = [116.397428, 39.90923];
                const randomOffset = (Math.random() - 0.5) * 0.02;
                const position = [
                    basePos[0] + randomOffset + (mapIndex * 0.005),
                    basePos[1] + randomOffset
                ];
                
                const color = resource.type === 'resource' ? '#2196F3' : '#FF5722';
                
                // 计算匹配度颜色
                let matchColor = '#FFC107'; // 默认黄色
                if (resource.finalMatchScore) {
                    const matchPercentage = Math.round(resource.finalMatchScore * 100);
                    if (matchPercentage >= 80) {
                        matchColor = '#4CAF50'; // 绿色
                    } else if (matchPercentage >= 60) {
                        matchColor = '#FF9800'; // 橙色
                    }
                }
                
                // 创建自定义标记，包含匹配度信息
        const matchPercentage = resource.finalMatchScore ? Math.round(resource.finalMatchScore * 100) : 0;
        const semanticScore = resource.semanticScore ? Math.round(resource.semanticScore * 100) : 0;
        const preferenceScore = resource.preferenceScore ? Math.round(resource.preferenceScore * 100) : 0;
        const distanceScore = resource.distanceScore ? Math.round(resource.distanceScore * 100) : 0;
        const categoryScore = resource.categoryScore ? Math.round(resource.categoryScore * 100) : 0;
        const semanticOverlap = resource.semanticOverlap ? Math.round(resource.semanticOverlap * 100) : 0;
        
        // 构建标记标题，包含完整的匹配信息
        let markerTitle = `${resource.title} (综合匹配度: ${matchPercentage}%)`;
        if (semanticScore > 0) markerTitle += `, 语义: ${semanticScore}%`;
        if (preferenceScore > 0) markerTitle += `, 偏好: ${preferenceScore}%`;
        if (distanceScore > 0) markerTitle += `, 距离: ${distanceScore}%`;
        if (categoryScore > 0) markerTitle += `, 分类: ${categoryScore}%`;
        if (semanticOverlap > 0) markerTitle += `, 语义重叠: ${semanticOverlap}%`;
        
        const marker = new AMap.Marker({
            position: position,
            map: map,
            title: markerTitle,
            content: `
                <div class="duck-marker">
                    <div class="pulse"></div>
                    <div class="duck-marker-icon" style="background: linear-gradient(135deg, ${color} 0%, ${color}80 100%);">
                        ${resource.icon}
                    </div>
                    <div class="match-percentage" style="background: ${matchColor};">
                        ${matchPercentage}%
                    </div>
                    <div class="semantic-score" style="background: #2196F3; bottom: -25px;">
                        语义: ${semanticScore}%
                    </div>
                    ${preferenceScore > 0 ? `<div class="preference-score" style="background: #4CAF50; bottom: -45px;">
                        偏好: ${preferenceScore}%
                    </div>` : ''}
                    ${distanceScore > 0 ? `<div class="distance-score" style="background: #FF9800; bottom: -65px;">
                        距离: ${distanceScore}%
                    </div>` : ''}
                    <div class="resource-type ${resource.type === 'demand' ? 'demand-type' : ''}">
                        ${resource.type === 'demand' ? '需' : '资'}
                    </div>
                </div>
            `
        });
                
                const actualIndex = categoryData[resource.category].resources.findIndex(r => r.title === resource.title);
                
                marker.on('click', function() {
                    showDetail(resource.category, actualIndex);
                });
                
                markers.push(marker);
            });
        } else {
            // 模拟地图的处理
            addMatchingPlaceholderMarkers(sortedResources);
        }
    
    // 更新地图中心（如果有匹配结果）
    if (sortedResources.length > 0 && map && mapLoaded) {
        map.setCenter(new AMap.LngLat(116.397428, 39.90923));
        map.setZoom(13);
    }
    
    // 显示匹配的资源列表
    showMatchingResources(sortedResources);
    
    // 隐藏加载状态
    setTimeout(hideLoading, 500);
}

// 搜索功能实现
function handleSearch(event) {
    console.log('========== 搜索事件触发 ==========');
    console.log('搜索事件:', event);
    console.log('搜索值:', event.target.value);
    handleRealTimeSearch(event);
}

// 在模拟地图上显示匹配的标记
function addMatchingPlaceholderMarkers(resources) {
    const mapContainer = document.getElementById('map-container');
    if (!mapContainer) return;
    
    // 清空现有标记
    const existingMarkers = mapContainer.querySelectorAll('.placeholder-marker');
    existingMarkers.forEach(marker => marker.remove());
    
    // 如果没有匹配结果，显示提示
    if (resources.length === 0) {
        const noResult = document.createElement('div');
        noResult.className = 'no-result';
        noResult.innerHTML = `
            <div class="no-result-icon">🔍</div>
            <div class="no-result-text">未找到匹配结果</div>
            <div class="no-result-hint">请尝试其他关键词</div>
        `;
        noResult.style.position = 'absolute';
        noResult.style.top = '50%';
        noResult.style.left = '50%';
        noResult.style.transform = 'translate(-50%, -50%)';
        noResult.style.textAlign = 'center';
        noResult.style.color = '#666';
        mapContainer.appendChild(noResult);
        return;
    }
    
    // 添加匹配的标记
    resources.forEach((resource, index) => {
        // 生成随机位置
        const left = `${10 + (index % 8) * 11}%`;
        const top = `${30 + Math.floor(index / 8) * 15}%`;
        
        const marker = document.createElement('div');
        marker.className = 'placeholder-marker';
        marker.style.position = 'absolute';
        marker.style.left = left;
        marker.style.top = top;
        marker.style.cursor = 'pointer';
        
        const color = resource.type === 'resource' ? '#2196F3' : '#FF5722';
        
        // 计算匹配度颜色
        let matchColor = '#FFC107'; // 默认黄色
        if (resource.finalMatchScore) {
            const matchPercentage = Math.round(resource.finalMatchScore * 100);
            if (matchPercentage >= 80) {
                matchColor = '#4CAF50'; // 绿色
            } else if (matchPercentage >= 60) {
                matchColor = '#FF9800'; // 橙色
            }
        }
        
        // 创建自定义标记，包含匹配度信息
        const matchPercentage = resource.finalMatchScore ? Math.round(resource.finalMatchScore * 100) : 0;
        const semanticScore = resource.semanticScore ? Math.round(resource.semanticScore * 100) : 0;
        const preferenceScore = resource.preferenceScore ? Math.round(resource.preferenceScore * 100) : 0;
        const distanceScore = resource.distanceScore ? Math.round(resource.distanceScore * 100) : 0;
        const categoryScore = resource.categoryScore ? Math.round(resource.categoryScore * 100) : 0;
        const semanticOverlap = resource.semanticOverlap ? Math.round(resource.semanticOverlap * 100) : 0;
        
        // 构建标记标题，包含完整的匹配信息
        let markerTitle = `${resource.title} (综合匹配度: ${matchPercentage}%)`;
        if (semanticScore > 0) markerTitle += `, 语义: ${semanticScore}%`;
        if (preferenceScore > 0) markerTitle += `, 偏好: ${preferenceScore}%`;
        if (distanceScore > 0) markerTitle += `, 距离: ${distanceScore}%`;
        if (categoryScore > 0) markerTitle += `, 分类: ${categoryScore}%`;
        if (semanticOverlap > 0) markerTitle += `, 语义重叠: ${semanticOverlap}%`;
        
        marker.innerHTML = `
            <div class="duck-marker">
                <div class="pulse"></div>
                <div class="duck-marker-icon" style="background: linear-gradient(135deg, ${color} 0%, ${color}80 100%);">
                    ${resource.icon}
                </div>
                <div class="match-percentage" style="background: ${matchColor};">
                    ${matchPercentage}%
                </div>
                <div class="semantic-score" style="background: #2196F3; bottom: -25px;">
                    语义: ${semanticScore}%
                </div>
                ${preferenceScore > 0 ? `<div class="preference-score" style="background: #4CAF50; bottom: -45px;">
                    偏好: ${preferenceScore}%
                </div>` : ''}
                ${distanceScore > 0 ? `<div class="distance-score" style="background: #FF9800; bottom: -65px;">
                    距离: ${distanceScore}%
                </div>` : ''}
                <div class="resource-type ${resource.type === 'demand' ? 'demand-type' : ''}">
                    ${resource.type === 'demand' ? '需' : '资'}
                </div>
                <div style="position:absolute;bottom:-75px;left:50%;transform:translateX(-50%);background:rgba(0,0,0,0.7);color:white;padding:4px 8px;border-radius:4px;font-size:12px;white-space:nowrap;">${resource.title}</div>
            </div>
        `;
        marker.title = markerTitle;
        
        const actualIndex = categoryData[resource.category].resources.findIndex(r => r.title === resource.title);
        
        marker.addEventListener('click', function() {
            showDetail(resource.category, actualIndex);
        });
        
        mapContainer.appendChild(marker);
    });
}

// 显示匹配的资源列表
function showMatchingResources(resources) {
    const resourceList = document.getElementById('resource-list');
    resourceList.innerHTML = '';
    
    if (resources.length === 0) {
        resourceList.innerHTML = `
            <div class="no-result">
                <div class="no-result-icon">🔍</div>
                <div class="no-result-text">未找到匹配的资源</div>
                <div class="no-result-hint">请尝试其他关键词</div>
            </div>
        `;
        return;
    }
    
    // 如果资源已经包含匹配分数，则使用该排序；否则使用默认排序
    let sortedResources = resources;
    if (!resources[0].hasOwnProperty('matchScore') && !resources[0].hasOwnProperty('finalMatchScore')) {
        // 按照距离和评分排序
        sortedResources.sort((a, b) => {
            // 提取距离数值（转换为公里数）
            const distanceA = parseFloat(a.distance);
            const distanceB = parseFloat(b.distance);
            
            // 提取信誉评分
            const ratingA = parseFloat(a.rating);
            const ratingB = parseFloat(b.rating);
            
            // 首先按距离排序（距离越近，匹配度越高）
            if (distanceA !== distanceB) {
                return distanceA - distanceB;
            }
            
            // 距离相同，按信誉评分排序（评分越高，排名越前）
            if (ratingA !== ratingB) {
                return ratingB - ratingA;
            }
            
            // 评分相同，按评价数量排序（评价数量越多，可信度越高）
            return (b.reviews || 0) - (a.reviews || 0);
        });
    }
    
    sortedResources.forEach(resource => {
        // 确定资源实际索引（考虑过滤后的情况）
        const actualIndex = categoryData[resource.category].resources.findIndex(r => r.title === resource.title);
        
        // 记录查看行为
        if (typeof personalizationService !== 'undefined') {
            // 模拟用户ID，实际应用中应该使用真实用户ID
            const userId = 'user_' + new Date().getTime();
            personalizationService.recordUserBehavior(userId, {
                type: 'view',
                resource: resource,
                timestamp: new Date().getTime()
            });
        }
        
        const card = document.createElement('div');
        card.className = 'resource-card';
        // 添加资源/需求标识
        const typeBadge = resource.type === 'demand' ? '<span class="demand-badge">需求</span>' : '';
        
        // 添加匹配分数和原因
        let matchInfo = '';
        if (resource.finalMatchScore) {
            // 显示综合匹配度
            const matchPercentage = Math.round(resource.finalMatchScore * 100);
            let matchLevel = '一般';
            let matchColor = '#FFC107';
            
            if (matchPercentage >= 80) {
                matchLevel = '高';
                matchColor = '#4CAF50';
            } else if (matchPercentage >= 60) {
                matchLevel = '中';
                matchColor = '#FF9800';
            }
            
            // 添加偏好匹配度信息
            let preferenceInfo = '';
            if (resource.preferenceScore) {
                const preferencePercentage = Math.round(resource.preferenceScore * 100);
                preferenceInfo = `<span class="preference-score" style="color: #2196F3;">偏好: ${preferencePercentage}%</span>`;
            }
            
            // 添加语义匹配度信息
            let semanticInfo = '';
            if (resource.semanticScore) {
                const semanticPercentage = Math.round(resource.semanticScore * 100);
                semanticInfo = `<span class="semantic-score" style="color: #9C27B0;">语义: ${semanticPercentage}%</span>`;
            }
            
            // 添加距离匹配度信息
            let distanceInfo = '';
            if (resource.distanceScore) {
                const distancePercentage = Math.round(resource.distanceScore * 100);
                distanceInfo = `<span class="distance-score" style="color: #FF5722;">距离: ${distancePercentage}%</span>`;
            }
            
            // 添加分类匹配度信息
            let categoryInfo = '';
            if (resource.categoryScore) {
                const categoryPercentage = Math.round(resource.categoryScore * 100);
                categoryInfo = `<span class="category-score" style="color: #795548;">分类: ${categoryPercentage}%</span>`;
            }
            
            // 添加语义重叠分析
            let overlapInfo = '';
            if (resource.semanticOverlap) {
                const overlapPercentage = Math.round(resource.semanticOverlap * 100);
                overlapInfo = `<span class="overlap-score" style="color: #673AB7;">语义重叠: ${overlapPercentage}%</span>`;
            }
            
            matchInfo = `
                <div class="card-match">
                    <div class="match-header">
                        <span class="match-score" style="color: ${matchColor};">综合匹配度: ${matchPercentage}%</span>
                        <span class="match-level" style="background-color: ${matchColor};">${matchLevel}</span>
                    </div>
                    <div class="match-details">
                        ${semanticInfo}
                        ${preferenceInfo}
                        ${distanceInfo}
                        ${categoryInfo}
                        ${overlapInfo}
                    </div>
                    ${resource.matchReasons && resource.matchReasons.length > 0 ? 
                        `<div class="match-reasons">
                            <span class="reasons-label">匹配原因:</span>
                            <ul class="reasons-list">
                                ${resource.matchReasons.map(reason => `<li>${reason}</li>`).join('')}
                            </ul>
                        </div>` : ''}
                    ${resource.semanticMatchReasons && resource.semanticMatchReasons.length > 0 ? 
                        `<div class="semantic-reasons">
                            <span class="reasons-label">语义匹配原因:</span>
                            <ul class="reasons-list">
                                ${resource.semanticMatchReasons.map(reason => `<li>${reason}</li>`).join('')}
                            </ul>
                        </div>` : ''}
                </div>
            `;
        } else if (resource.matchScore) {
            // 显示原始匹配度
            const matchPercentage = Math.round(resource.matchScore * 100);
            let matchLevel = '一般';
            let matchColor = '#FFC107';
            
            if (matchPercentage >= 80) {
                matchLevel = '高';
                matchColor = '#4CAF50';
            } else if (matchPercentage >= 60) {
                matchLevel = '中';
                matchColor = '#FF9800';
            }
            
            // 添加语义匹配度信息
            let semanticInfo = '';
            if (resource.semanticScore) {
                const semanticPercentage = Math.round(resource.semanticScore * 100);
                semanticInfo = `<span class="semantic-score" style="color: #9C27B0;">语义: ${semanticPercentage}%</span>`;
            }
            
            matchInfo = `
                <div class="card-match">
                    <div class="match-header">
                        <span class="match-score" style="color: ${matchColor};">匹配度: ${matchPercentage}%</span>
                        <span class="match-level" style="background-color: ${matchColor};">${matchLevel}</span>
                    </div>
                    <div class="match-details">
                        ${semanticInfo}
                    </div>
                    ${resource.matchReasons && resource.matchReasons.length > 0 ? 
                        `<div class="match-reasons">
                            <span class="reasons-label">匹配原因:</span>
                            <ul class="reasons-list">
                                ${resource.matchReasons.map(reason => `<li>${reason}</li>`).join('')}
                            </ul>
                        </div>` : ''}
                </div>
            `;
        }
        
        card.innerHTML = `
            <div class="card-icon">${resource.icon}</div>
            <div class="card-info">
                <div class="card-title">${resource.title}${typeBadge}</div>
                <div class="card-meta">
                    <span>📍 ${resource.distance}</span>
                    <span>⭐ ${resource.rating}</span>
                </div>
                ${matchInfo}
            </div>
            <div class="card-price">${resource.price}</div>
        `;
        card.addEventListener('click', function() {
            showDetail(resource.category, actualIndex, resource);
        });
        resourceList.appendChild(card);
    });
}

// 清空地图标记
function clearMarkers() {
    // 清空真实地图API的标记
    markers.forEach(marker => {
        if (marker && marker.setMap) {
            marker.setMap(null);
        }
    });
    markers = [];
    
    // 清空模拟地图的标记
    const mapContainer = document.getElementById('map-container');
    if (mapContainer) {
        const placeholderMarkers = mapContainer.querySelectorAll('.placeholder-marker');
        placeholderMarkers.forEach(marker => marker.remove());
        
        const noResults = mapContainer.querySelectorAll('.no-result');
        noResults.forEach(result => result.remove());
    }
}

// 显示加载状态
function showLoading() {
    // 创建加载容器
    let loadingContainer = document.getElementById('loading-container');
    if (!loadingContainer) {
        loadingContainer = document.createElement('div');
        loadingContainer.id = 'loading-container';
        loadingContainer.className = 'loading-container';
        loadingContainer.style.position = 'fixed';
        loadingContainer.style.top = '0';
        loadingContainer.style.left = '0';
        loadingContainer.style.width = '100%';
        loadingContainer.style.height = '100%';
        loadingContainer.style.backgroundColor = 'rgba(255, 255, 255, 0.9)';
        loadingContainer.style.display = 'flex';
        loadingContainer.style.flexDirection = 'column';
        loadingContainer.style.alignItems = 'center';
        loadingContainer.style.justifyContent = 'center';
        loadingContainer.style.zIndex = '9999';
        loadingContainer.innerHTML = `
            <div class="loading-spinner"></div>
            <div class="loading-text">正在搜索资源...</div>
        `;
        document.body.appendChild(loadingContainer);
    } else {
        loadingContainer.style.display = 'flex';
    }
}

// 隐藏加载状态
function hideLoading() {
    const loadingContainer = document.getElementById('loading-container');
    if (loadingContainer) {
        loadingContainer.style.display = 'none';
    }
}

// 测试搜索功能
function testSearchFunctionality() {
    console.log('========== 测试搜索功能 ==========');
    console.log('handleSearch函数:', typeof handleSearch);
    console.log('handleRealTimeSearch函数:', typeof handleRealTimeSearch);
    console.log('performSearch函数:', typeof performSearch);
    
    if (typeof handleSearch === 'function') {
        console.log('handleSearch函数存在');
    } else {
        console.log('handleSearch函数不存在');
    }
    
    if (typeof handleRealTimeSearch === 'function') {
        console.log('handleRealTimeSearch函数存在');
    } else {
        console.log('handleRealTimeSearch函数不存在');
    }
    
    if (typeof performSearch === 'function') {
        console.log('performSearch函数存在');
    } else {
        console.log('performSearch函数不存在');
    }
    
    // 测试直接调用performSearch
    console.log('========== 测试直接调用performSearch ==========');
    if (typeof performSearch === 'function') {
        console.log('准备测试直接调用performSearch');
        const testConditions = {
            keyword: '测试搜索',
            category: 'all',
            maxDistance: 50,
            minRating: 0,
            priceRange: { min: 0, max: 999999 }
        };
        performSearch(testConditions).then(() => {
            console.log('performSearch调用成功');
        }).catch((error) => {
            console.error('performSearch调用失败:', error);
        });
    }
}

// 页面加载完成后测试
if (typeof window !== 'undefined') {
    window.onload = function() {
        console.log('========== 页面加载完成 ==========');
        console.log('页面加载完成，准备测试搜索功能');
        // 延迟1秒后测试，确保所有脚本都已加载
        setTimeout(testSearchFunctionality, 1000);
    };
}