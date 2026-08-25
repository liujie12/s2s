/**
 * 性能优化与并发测试脚本
 * 测试不同匹配模式的性能，并进行并发测试
 */
class PerformanceTest {
    /**
     * 构造函数
     * @param {Object} options 配置选项
     */
    constructor(options = {}) {
        this.config = {
            concurrencyLevels: [1, 5, 10, 20, 50], // 并发级别
            testDuration: 3000, // 测试持续时间（毫秒）
            warmupRequests: 10, // 预热请求数
            ...options
        };
        
        // 初始化模块
        this.initModules();
        
        // 模拟资源数据
        this.mockResources = this.generateMockResources(100);
        
        // 测试用例
        this.testCases = [
            {
                name: '快速匹配 - 短查询',
                mode: 'fast',
                query: '北京办公室',
                params: {
                    query: '北京办公室',
                    location: { lat: 39.915, lng: 116.404 },
                    category: '办公空间'
                }
            },
            {
                name: '快速匹配 - 长查询',
                mode: 'fast',
                query: '北京市朝阳区CBD核心区域办公室出租',
                params: {
                    query: '北京市朝阳区CBD核心区域办公室出租',
                    location: { lat: 39.915, lng: 116.404 },
                    category: '办公空间'
                }
            },
            {
                name: '深度匹配 - 短查询',
                mode: 'deep',
                query: '北京办公室',
                params: {
                    query: '北京办公室',
                    location: { lat: 39.915, lng: 116.404 },
                    category: '办公空间'
                }
            },
            {
                name: '深度匹配 - 长查询',
                mode: 'deep',
                query: '北京市朝阳区CBD核心区域办公室出租',
                params: {
                    query: '北京市朝阳区CBD核心区域办公室出租',
                    location: { lat: 39.915, lng: 116.404 },
                    category: '办公空间'
                }
            },
            {
                name: '语义精准匹配 - 短查询',
                mode: 'semantic',
                query: '北京办公室',
                params: {
                    query: '北京办公室',
                    location: { lat: 39.915, lng: 116.404 },
                    category: '办公空间'
                }
            },
            {
                name: '语义精准匹配 - 长查询',
                mode: 'semantic',
                query: '北京市朝阳区CBD核心区域办公室出租',
                params: {
                    query: '北京市朝阳区CBD核心区域办公室出租',
                    location: { lat: 39.915, lng: 116.404 },
                    category: '办公空间'
                }
            }
        ];
    }

    /**
     * 初始化模块
     */
    initModules() {
        // 导入匹配模块
        this.fastMatcher = window.FastMatcher ? new window.FastMatcher() : null;
        this.deepMatcher = window.DeepMatcher ? new window.DeepMatcher() : null;
        this.semanticPreciseMatcher = window.SemanticPreciseMatcher ? new window.SemanticPreciseMatcher() : null;
        this.smartTrigger = window.SmartTrigger ? new window.SmartTrigger() : null;
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
     * 预热系统
     * @param {Object} testCase 测试用例
     */
    async warmup(testCase) {
        console.log(`预热系统: ${testCase.name}`);
        
        for (let i = 0; i < this.config.warmupRequests; i++) {
            await this.executeTestRequest(testCase);
        }
        
        console.log(`预热完成: ${testCase.name}`);
    }

    /**
     * 执行测试请求
     * @param {Object} testCase 测试用例
     * @returns {Promise<Object>} 请求结果
     */
    async executeTestRequest(testCase) {
        const startTime = Date.now();
        let result;
        
        try {
            switch (testCase.mode) {
                case 'fast':
                    if (this.fastMatcher) {
                        result = await this.fastMatcher.match(this.mockResources, testCase.params);
                    }
                    break;
                case 'deep':
                    if (this.deepMatcher) {
                        result = await this.deepMatcher.match(this.mockResources, testCase.params);
                    }
                    break;
                case 'semantic':
                    if (this.semanticPreciseMatcher) {
                        result = await this.semanticPreciseMatcher.match(this.mockResources, testCase.params);
                    }
                    break;
            }
        } catch (error) {
            console.error(`请求失败: ${testCase.name}`, error);
        }
        
        const endTime = Date.now();
        
        return {
            startTime,
            endTime,
            duration: endTime - startTime,
            result
        };
    }

    /**
     * 运行单模式性能测试
     * @param {Object} testCase 测试用例
     * @returns {Promise<Object>} 测试结果
     */
    async runSingleModeTest(testCase) {
        console.log(`\n=== 运行单模式性能测试: ${testCase.name} ===`);
        
        // 预热
        await this.warmup(testCase);
        
        const results = [];
        const startTime = Date.now();
        
        // 执行测试
        while (Date.now() - startTime < this.config.testDuration) {
            const result = await this.executeTestRequest(testCase);
            results.push(result);
        }
        
        // 计算统计数据
        const stats = this.calculateStats(results);
        
        console.log(`测试结果: ${testCase.name}`);
        console.log(`总请求数: ${results.length}`);
        console.log(`QPS: ${stats.qps.toFixed(2)}`);
        console.log(`平均响应时间: ${stats.avgTime.toFixed(2)}ms`);
        console.log(`最小响应时间: ${stats.minTime}ms`);
        console.log(`最大响应时间: ${stats.maxTime}ms`);
        console.log(`95% 响应时间: ${stats.p95Time}ms`);
        console.log(`99% 响应时间: ${stats.p99Time}ms`);
        console.log(`错误率: ${stats.errorRate.toFixed(2)}%`);
        
        return {
            testCase,
            results,
            stats
        };
    }

    /**
     * 运行并发测试
     * @param {Object} testCase 测试用例
     * @param {number} concurrency 并发级别
     * @returns {Promise<Object>} 测试结果
     */
    async runConcurrencyTest(testCase, concurrency) {
        console.log(`\n=== 运行并发测试: ${testCase.name} (并发: ${concurrency}) ===`);
        
        // 预热
        await this.warmup(testCase);
        
        const results = [];
        const startTime = Date.now();
        
        // 执行并发测试
        while (Date.now() - startTime < this.config.testDuration) {
            const promises = [];
            
            // 创建并发请求
            for (let i = 0; i < concurrency; i++) {
                promises.push(this.executeTestRequest(testCase));
            }
            
            // 等待所有请求完成
            const batchResults = await Promise.all(promises);
            results.push(...batchResults);
        }
        
        // 计算统计数据
        const stats = this.calculateStats(results);
        
        console.log(`并发测试结果: ${testCase.name} (并发: ${concurrency})`);
        console.log(`总请求数: ${results.length}`);
        console.log(`QPS: ${stats.qps.toFixed(2)}`);
        console.log(`平均响应时间: ${stats.avgTime.toFixed(2)}ms`);
        console.log(`最小响应时间: ${stats.minTime}ms`);
        console.log(`最大响应时间: ${stats.maxTime}ms`);
        console.log(`95% 响应时间: ${stats.p95Time}ms`);
        console.log(`99% 响应时间: ${stats.p99Time}ms`);
        console.log(`错误率: ${stats.errorRate.toFixed(2)}%`);
        
        return {
            testCase,
            concurrency,
            results,
            stats
        };
    }

    /**
     * 计算统计数据
     * @param {Array} results 测试结果
     * @returns {Object} 统计数据
     */
    calculateStats(results) {
        if (results.length === 0) {
            return {
                qps: 0,
                avgTime: 0,
                minTime: 0,
                maxTime: 0,
                p95Time: 0,
                p99Time: 0,
                errorRate: 0
            };
        }
        
        // 过滤出成功的结果
        const successfulResults = results.filter(r => r.duration > 0);
        const errorCount = results.length - successfulResults.length;
        
        // 计算响应时间
        const durations = successfulResults.map(r => r.duration).sort((a, b) => a - b);
        
        // 计算统计数据
        const totalTime = durations.reduce((sum, time) => sum + time, 0);
        const avgTime = totalTime / durations.length;
        const minTime = durations[0];
        const maxTime = durations[durations.length - 1];
        const p95Time = durations[Math.floor(durations.length * 0.95)];
        const p99Time = durations[Math.floor(durations.length * 0.99)];
        const errorRate = (errorCount / results.length) * 100;
        
        // 计算QPS
        const testDuration = results[results.length - 1].endTime - results[0].startTime;
        const qps = results.length / (testDuration / 1000);
        
        return {
            qps,
            avgTime,
            minTime,
            maxTime,
            p95Time,
            p99Time,
            errorRate
        };
    }

    /**
     * 运行所有测试
     * @returns {Promise<Object>} 所有测试结果
     */
    async runAllTests() {
        console.log('=== 开始性能测试 ===\n');
        
        const allResults = {
            singleModeTests: [],
            concurrencyTests: []
        };
        
        // 运行单模式性能测试
        console.log('=== 运行单模式性能测试 ===\n');
        for (const testCase of this.testCases) {
            const result = await this.runSingleModeTest(testCase);
            allResults.singleModeTests.push(result);
        }
        
        // 运行并发测试
        console.log('\n=== 运行并发测试 ===\n');
        for (const testCase of this.testCases) {
            for (const concurrency of this.config.concurrencyLevels) {
                const result = await this.runConcurrencyTest(testCase, concurrency);
                allResults.concurrencyTests.push(result);
            }
        }
        
        // 生成测试报告
        this.generateTestReport(allResults);
        
        console.log('\n=== 性能测试完成 ===');
        
        return allResults;
    }

    /**
     * 生成测试报告
     * @param {Object} allResults 所有测试结果
     */
    generateTestReport(allResults) {
        console.log('\n=== 性能测试报告 ===\n');
        
        // 单模式测试摘要
        console.log('=== 单模式测试摘要 ===');
        allResults.singleModeTests.forEach(result => {
            console.log(`${result.testCase.name}:`);
            console.log(`  QPS: ${result.stats.qps.toFixed(2)}`);
            console.log(`  平均响应时间: ${result.stats.avgTime.toFixed(2)}ms`);
            console.log(`  95% 响应时间: ${result.stats.p95Time}ms`);
            console.log(`  错误率: ${result.stats.errorRate.toFixed(2)}%`);
        });
        
        // 并发测试摘要
        console.log('\n=== 并发测试摘要 ===');
        for (const concurrency of this.config.concurrencyLevels) {
            console.log(`并发级别: ${concurrency}`);
            allResults.concurrencyTests
                .filter(result => result.concurrency === concurrency)
                .forEach(result => {
                    console.log(`  ${result.testCase.name}:`);
                    console.log(`    QPS: ${result.stats.qps.toFixed(2)}`);
                    console.log(`    平均响应时间: ${result.stats.avgTime.toFixed(2)}ms`);
                    console.log(`    95% 响应时间: ${result.stats.p95Time}ms`);
                    console.log(`    错误率: ${result.stats.errorRate.toFixed(2)}%`);
                });
        }
        
        // 性能分析
        console.log('\n=== 性能分析 ===');
        console.log('1. 不同匹配模式性能对比:');
        const modeStats = {};
        
        allResults.singleModeTests.forEach(result => {
            const mode = result.testCase.mode;
            if (!modeStats[mode]) {
                modeStats[mode] = [];
            }
            modeStats[mode].push(result.stats);
        });
        
        for (const [mode, statsList] of Object.entries(modeStats)) {
            const avgQps = statsList.reduce((sum, stats) => sum + stats.qps, 0) / statsList.length;
            const avgTime = statsList.reduce((sum, stats) => sum + stats.avgTime, 0) / statsList.length;
            console.log(`  ${this.getModeName(mode)}:`);
            console.log(`    平均QPS: ${avgQps.toFixed(2)}`);
            console.log(`    平均响应时间: ${avgTime.toFixed(2)}ms`);
        }
        
        console.log('\n2. 并发性能分析:');
        for (const testCase of this.testCases) {
            console.log(`  ${testCase.name}:`);
            allResults.concurrencyTests
                .filter(result => result.testCase.name === testCase.name)
                .forEach(result => {
                    console.log(`    并发 ${result.concurrency}: QPS = ${result.stats.qps.toFixed(2)}, 平均响应时间 = ${result.stats.avgTime.toFixed(2)}ms`);
                });
        }
        
        // 性能优化建议
        console.log('\n=== 性能优化建议 ===');
        console.log('1. 快速匹配模式:');
        console.log('   - 进一步优化缓存策略，增加缓存命中率');
        console.log('   - 使用空间索引（如R树）优化地理位置查询');
        console.log('   - 考虑使用Web Workers进行并行计算');
        
        console.log('\n2. 深度匹配模式:');
        console.log('   - 优化权重计算算法，减少计算复杂度');
        console.log('   - 考虑使用矩阵运算库进行批量计算');
        console.log('   - 实现结果缓存，避免重复计算');
        
        console.log('\n3. 语义精准匹配模式:');
        console.log('   - 优化向量计算，考虑使用WebAssembly加速');
        console.log('   - 实现向量索引，加速相似度计算');
        console.log('   - 考虑使用服务端预计算向量，减少客户端计算负担');
        
        console.log('\n4. 并发处理:');
        console.log('   - 实现请求队列，避免系统过载');
        console.log('   - 优化资源池管理，减少资源竞争');
        console.log('   - 考虑使用限流策略，保护系统稳定性');
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
            semantic: '语义精准匹配'
        };
        
        return modeNames[mode] || mode;
    }
}

// 运行测试
function runPerformanceTests() {
    console.log('=== 性能优化与并发测试 ===\n');
    
    const performanceTest = new PerformanceTest();
    performanceTest.runAllTests()
        .then(results => {
            console.log('测试完成');
        })
        .catch(error => {
            console.error('测试失败:', error);
        });
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        PerformanceTest,
        runPerformanceTests
    };
} else if (typeof window !== 'undefined') {
    window.PerformanceTest = PerformanceTest;
    window.runPerformanceTests = runPerformanceTests;
    console.log('性能测试脚本已加载，请调用 runPerformanceTests() 运行测试');
}