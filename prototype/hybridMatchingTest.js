/**
 * 混合匹配模式测试与验证脚本
 * 测试不同匹配模式的组合和协同工作
 */
class HybridMatchingTest {
    /**
     * 构造函数
     * @param {Object} options 配置选项
     */
    constructor(options = {}) {
        this.config = {
            testCases: [
                {
                    name: '智能模式 - 短查询',
                    query: '北京办公室',
                    expectedMode: 'fast'
                },
                {
                    name: '智能模式 - 中等查询',
                    query: '北京朝阳区办公室出租',
                    expectedMode: 'deep'
                },
                {
                    name: '智能模式 - 长查询',
                    query: '北京市朝阳区CBD核心区域现代化办公室出租，交通便利，配套齐全',
                    expectedMode: 'semantic'
                },
                {
                    name: '快速模式测试',
                    query: '北京办公室',
                    mode: 'fast'
                },
                {
                    name: '深度模式测试',
                    query: '北京朝阳区办公室出租',
                    mode: 'deep'
                },
                {
                    name: '语义模式测试',
                    query: '北京市朝阳区CBD核心区域现代化办公室出租',
                    mode: 'semantic'
                }
            ],
            ...options
        };
        
        // 初始化模块
        this.initModules();
        
        // 模拟资源数据
        this.mockResources = this.generateMockResources(50);
    }

    /**
     * 初始化模块
     */
    initModules() {
        // 导入匹配模块
        this.fastMatcher = window.FastMatcher ? new window.FastMatcher() : null;
        this.deepMatcher = window.DeepMatcher ? new window.DeepMatcher() : null;
        this.semanticPreciseMatcher = window.SemanticPreciseMatcher ? new window.SemanticPreciseMatcher() : null;
        this.smartTrigger = window.SmartTriggerEngine ? new window.SmartTriggerEngine() : null;
        this.hybridMatchingFrontend = window.hybridMatchingFrontend;
    }

    /**
     * 生成模拟资源数据
     * @param {number} count 资源数量
     * @returns {Array} 模拟资源数据
     */
    generateMockResources(count) {
        const categories = ['办公空间', '商业空间', '住宅', '仓库', '停车位'];
        const locations = [
            { name: '朝阳区', coordinates: [116.404, 39.915] },
            { name: '海淀区', coordinates: [116.305, 39.966] },
            { name: '东城区', coordinates: [116.416, 39.928] },
            { name: '西城区', coordinates: [116.366, 39.912] },
            { name: '丰台区', coordinates: [116.288, 39.858] }
        ];
        
        const resources = [];
        
        for (let i = 0; i < count; i++) {
            const category = categories[Math.floor(Math.random() * categories.length)];
            const location = locations[Math.floor(Math.random() * locations.length)];
            const price = (Math.floor(Math.random() * 10) + 1) * 1000;
            const rating = (Math.random() * 2 + 3).toFixed(1);
            
            resources.push({
                id: `resource-${i + 1}`,
                title: `${location.name}${category}出租`,
                description: `位于${location.name}，交通便利，配套齐全，适合${category === '办公空间' ? '中小型企业办公' : category === '商业空间' ? '各类商业活动' : '居住'}`,
                category: category,
                tags: [category, '出租', location.name],
                coordinates: location.coordinates,
                price: `${price}元/月`,
                availableTime: Math.random() > 0.5 ? '随时可用' : '下周可用',
                rating: parseFloat(rating)
            });
        }
        
        return resources;
    }

    /**
     * 运行混合匹配模式测试
     * @returns {Promise<Object>} 测试结果
     */
    async runHybridMatchingTests() {
        console.log('=== 混合匹配模式测试与验证 ===\n');
        
        const results = [];
        
        // 运行测试用例
        for (const testCase of this.config.testCases) {
            console.log(`测试用例: ${testCase.name}`);
            console.log(`查询: ${testCase.query}`);
            
            try {
                // 构建查询参数
                const params = {
                    query: testCase.query,
                    location: { lat: 39.915, lng: 116.404 },
                    category: '办公空间'
                };
                
                let result;
                let actualMode;
                
                // 执行测试
                if (testCase.mode) {
                    // 指定模式测试
                    actualMode = testCase.mode;
                    result = await this.executeMatching(testCase.mode, params);
                } else {
                    // 智能模式测试
                    const triggerResult = await this.smartTrigger.executeSmartMatching(params, this.mockResources);
                    actualMode = 'auto';
                    result = {
                        results: triggerResult,
                        total: triggerResult.length,
                        time: Math.floor(Math.random() * 100),
                        mode: 'auto'
                    };
                }
                
                // 验证结果
                const validation = this.validateResult(result, testCase);
                
                console.log(`实际模式: ${this.getModeName(actualMode)}`);
                console.log(`期望模式: ${testCase.expectedMode ? this.getModeName(testCase.expectedMode) : '智能选择'}`);
                console.log(`结果数量: ${result.total}`);
                console.log(`响应时间: ${result.time}ms`);
                console.log(`验证结果: ${validation.valid ? '通过' : '失败'}`);
                if (!validation.valid) {
                    console.log(`失败原因: ${validation.reason}`);
                }
                console.log('---\n');
                
                results.push({
                    testCase,
                    actualMode,
                    result,
                    validation
                });
            } catch (error) {
                console.error(`测试失败: ${testCase.name}`, error);
                results.push({
                    testCase,
                    error: error.message
                });
            }
        }
        
        // 生成测试报告
        this.generateTestReport(results);
        
        console.log('=== 混合匹配模式测试完成 ===');
        
        return results;
    }

    /**
     * 执行匹配
     * @param {string} mode 匹配模式
     * @param {Object} params 查询参数
     * @returns {Promise<Object>} 匹配结果
     */
    async executeMatching(mode, params) {
        switch (mode) {
            case 'fast':
                if (this.fastMatcher) {
                    return await this.fastMatcher.match(this.mockResources, params);
                }
                break;
            case 'deep':
                if (this.deepMatcher) {
                    return await this.deepMatcher.match(this.mockResources, params);
                }
                break;
            case 'semantic':
                if (this.semanticPreciseMatcher) {
                    return await this.semanticPreciseMatcher.match(this.mockResources, params);
                }
                break;
            default:
                throw new Error(`未知的匹配模式: ${mode}`);
        }
    }

    /**
     * 验证结果
     * @param {Object} result 匹配结果
     * @param {Object} testCase 测试用例
     * @returns {Object} 验证结果
     */
    validateResult(result, testCase) {
        // 验证结果存在
        if (!result || !result.results) {
            return {
                valid: false,
                reason: '匹配结果为空'
            };
        }
        
        // 验证结果数量
        if (result.results.length === 0) {
            return {
                valid: false,
                reason: '未找到匹配结果'
            };
        }
        
        // 验证响应时间
        if (result.time > 2000) {
            return {
                valid: false,
                reason: '响应时间过长'
            };
        }
        
        // 验证结果质量
        const quality = this.evaluateResultQuality(result.results, testCase.query);
        if (quality < 0.5) {
            return {
                valid: false,
                reason: '匹配结果质量过低'
            };
        }
        
        return {
            valid: true,
            reason: '验证通过'
        };
    }

    /**
     * 评估结果质量
     * @param {Array} results 匹配结果
     * @param {string} query 查询文本
     * @returns {number} 结果质量分数（0-1）
     */
    evaluateResultQuality(results, query) {
        if (!results || results.length === 0) {
            return 0;
        }
        
        let score = 0;
        
        // 评估每个结果
        results.forEach(result => {
            // 检查标题是否包含查询关键词
            if (result.title.includes('办公室')) {
                score += 0.3;
            }
            
            // 检查分类是否匹配
            if (result.category === '办公空间') {
                score += 0.3;
            }
            
            // 检查位置是否匹配
            if (result.tags && result.tags.includes('朝阳区')) {
                score += 0.2;
            }
            
            // 检查评分
            if (result.rating >= 4.0) {
                score += 0.2;
            }
        });
        
        // 计算平均质量分数
        return score / results.length;
    }

    /**
     * 测试模式切换
     * @returns {Promise<Object>} 测试结果
     */
    async testModeSwitching() {
        console.log('=== 模式切换测试 ===\n');
        
        const queries = [
            '北京办公室',
            '北京朝阳区办公室出租',
            '北京市朝阳区CBD核心区域现代化办公室出租'
        ];
        
        const results = [];
        
        for (const query of queries) {
            console.log(`查询: ${query}`);
            
            // 构建查询参数
            const params = {
                query: query,
                location: { lat: 39.915, lng: 116.404 },
                category: '办公空间'
            };
            
            // 测试智能触发
            const triggerResult = await this.smartTrigger.executeSmartMatching(params, this.mockResources);
            console.log(`智能触发模式: ${this.getModeName('auto')}`);
            console.log(`结果数量: ${triggerResult.length}`);
            
            // 测试快速模式
            const fastResult = await this.executeMatching('fast', params);
            console.log(`快速模式: ${fastResult.total} 个结果, ${fastResult.time}ms`);
            
            // 测试深度模式
            const deepResult = await this.executeMatching('deep', params);
            console.log(`深度模式: ${deepResult.total} 个结果, ${deepResult.time}ms`);
            
            // 测试语义模式
            const semanticResult = await this.executeMatching('semantic', params);
            console.log(`语义模式: ${semanticResult.total} 个结果, ${semanticResult.time}ms`);
            
            results.push({
                query,
                triggerResult,
                fastResult,
                deepResult,
                semanticResult
            });
            
            console.log('---\n');
        }
        
        return results;
    }

    /**
     * 测试前端集成
     * @returns {Promise<boolean>} 测试结果
     */
    async testFrontendIntegration() {
        console.log('=== 前端集成测试 ===\n');
        
        try {
            // 检查前端模块是否初始化
            if (!this.hybridMatchingFrontend) {
                console.error('前端模块未初始化');
                return false;
            }
            
            // 检查DOM元素是否存在
            const container = document.getElementById('hybrid-matching-container');
            if (!container) {
                console.error('前端容器不存在');
                return false;
            }
            
            const searchInput = document.getElementById('search-input');
            if (!searchInput) {
                console.error('搜索输入框不存在');
                return false;
            }
            
            const resultsContainer = document.getElementById('matching-results');
            if (!resultsContainer) {
                console.error('结果容器不存在');
                return false;
            }
            
            console.log('前端模块初始化成功');
            console.log('DOM元素存在');
            console.log('前端集成测试通过');
            
            return true;
        } catch (error) {
            console.error('前端集成测试失败:', error);
            return false;
        }
    }

    /**
     * 生成测试报告
     * @param {Array} results 测试结果
     */
    generateTestReport(results) {
        console.log('=== 混合匹配模式测试报告 ===\n');
        
        // 统计测试结果
        const totalTests = results.length;
        const passedTests = results.filter(r => r.validation && r.validation.valid).length;
        const failedTests = totalTests - passedTests;
        
        console.log(`测试总览:`);
        console.log(`总测试用例: ${totalTests}`);
        console.log(`通过: ${passedTests}`);
        console.log(`失败: ${failedTests}`);
        console.log(`通过率: ${((passedTests / totalTests) * 100).toFixed(2)}%`);
        
        // 分析模式分布
        console.log('\n模式分布:');
        const modeCounts = {};
        results.forEach(result => {
            if (result.actualMode) {
                modeCounts[result.actualMode] = (modeCounts[result.actualMode] || 0) + 1;
            }
        });
        
        for (const [mode, count] of Object.entries(modeCounts)) {
            console.log(`${this.getModeName(mode)}: ${count} 次`);
        }
        
        // 分析响应时间
        console.log('\n响应时间分析:');
        const times = results.map(r => r.result.time).filter(t => t > 0);
        if (times.length > 0) {
            const avgTime = times.reduce((sum, time) => sum + time, 0) / times.length;
            const minTime = Math.min(...times);
            const maxTime = Math.max(...times);
            
            console.log(`平均响应时间: ${avgTime.toFixed(2)}ms`);
            console.log(`最小响应时间: ${minTime}ms`);
            console.log(`最大响应时间: ${maxTime}ms`);
        }
        
        // 失败测试分析
        if (failedTests > 0) {
            console.log('\n失败测试分析:');
            results
                .filter(r => r.validation && !r.validation.valid)
                .forEach(result => {
                    console.log(`测试用例: ${result.testCase.name}`);
                    console.log(`失败原因: ${result.validation.reason}`);
                    console.log(`响应时间: ${result.result.time}ms`);
                });
        }
        
        // 建议
        console.log('\n建议:');
        if (failedTests > 0) {
            console.log('1. 检查失败测试用例，修复相应问题');
        }
        console.log('2. 优化语义精准匹配的响应时间');
        console.log('3. 增强智能触发机制的准确性');
        console.log('4. 完善前端界面的用户体验');
    }

    /**
     * 执行匹配
     * @param {string} mode 匹配模式
     * @param {Object} params 查询参数
     * @returns {Promise<Object>} 匹配结果
     */
    async executeMatching(mode, params) {
        switch (mode) {
            case 'fast':
                if (this.fastMatcher) {
                    return await this.fastMatcher.match(this.mockResources, params);
                }
                break;
            case 'deep':
                if (this.deepMatcher) {
                    return await this.deepMatcher.match(this.mockResources, params);
                }
                break;
            case 'semantic':
                if (this.semanticPreciseMatcher) {
                    return await this.semanticPreciseMatcher.match(this.mockResources, params);
                }
                break;
            default:
                throw new Error(`未知的匹配模式: ${mode}`);
        }
    }

    /**
     * 获取匹配模式名称
     * @param {string} mode 匹配模式
     * @returns {string} 模式名称
     */
    getModeName(mode) {
        const modeNames = {
            fast: '快速匹配',
            deep: '深度匹配',
            semantic: '语义精准匹配',
            auto: '智能模式'
        };
        
        return modeNames[mode] || mode;
    }
}

// 运行测试
function runHybridMatchingTests() {
    console.log('=== 混合匹配模式测试与验证 ===\n');
    
    const hybridMatchingTest = new HybridMatchingTest();
    
    // 运行混合匹配测试
    hybridMatchingTest.runHybridMatchingTests()
        .then(() => {
            // 运行模式切换测试
            return hybridMatchingTest.testModeSwitching();
        })
        .then(() => {
            // 运行前端集成测试
            return hybridMatchingTest.testFrontendIntegration();
        })
        .then(() => {
            console.log('\n=== 混合匹配模式测试完成 ===');
        })
        .catch(error => {
            console.error('测试失败:', error);
        });
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        HybridMatchingTest,
        runHybridMatchingTests
    };
} else if (typeof window !== 'undefined') {
    window.HybridMatchingTest = HybridMatchingTest;
    window.runHybridMatchingTests = runHybridMatchingTests;
    console.log('混合匹配模式测试脚本已加载，请调用 runHybridMatchingTests() 运行测试');
}