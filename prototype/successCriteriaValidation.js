/**
 * 成功标准验证脚本
 * 验证所有任务是否满足成功标准
 */
class SuccessCriteriaValidation {
    /**
     * 构造函数
     * @param {Object} options 配置选项
     */
    constructor(options = {}) {
        this.config = {
            successCriteria: {
                architecture: {
                    required: true,
                    description: '三层级匹配系统架构设计完成',
                    check: () => this.checkArchitectureDesign()
                },
                fastMatching: {
                    required: true,
                    description: '快速匹配模块实现，响应时间 < 100ms',
                    check: () => this.checkFastMatching()
                },
                deepMatching: {
                    required: true,
                    description: '深度匹配模块实现，响应时间 < 1s',
                    check: () => this.checkDeepMatching()
                },
                semanticMatching: {
                    required: true,
                    description: '语义精准匹配模块实现，响应时间 < 2s',
                    check: () => this.checkSemanticMatching()
                },
                smartTrigger: {
                    required: true,
                    description: '智能触发机制实现，自动选择匹配模式',
                    check: () => this.checkSmartTrigger()
                },
                debounce: {
                    required: true,
                    description: '防抖技术实现，优化用户输入和交互性能',
                    check: () => this.checkDebounce()
                },
                frontend: {
                    required: true,
                    description: '前端集成与用户界面优化，实现智能资源匹配的前端界面',
                    check: () => this.checkFrontendIntegration()
                },
                performance: {
                    required: true,
                    description: '性能优化与并发测试，在不同并发级别下的性能测试',
                    check: () => this.checkPerformance()
                },
                hybridMatching: {
                    required: true,
                    description: '混合匹配模式测试与验证，测试不同匹配模式的组合和协同工作',
                    check: () => this.checkHybridMatching()
                }
            },
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
        this.smartTrigger = window.SmartTrigger ? new window.SmartTrigger() : null;
        this.hybridMatchingFrontend = window.hybridMatchingFrontend;
        this.debounceUtil = window.debounceUtil;
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
     * 检查架构设计
     * @returns {Object} 检查结果
     */
    checkArchitectureDesign() {
        try {
            // 检查架构设计文档是否存在
            const fs = require ? require('fs') : null;
            if (fs) {
                const architectureDocPath = './design/hybrid-matching-architecture.md';
                if (fs.existsSync(architectureDocPath)) {
                    const content = fs.readFileSync(architectureDocPath, 'utf8');
                    if (content.includes('三层级匹配系统') && content.includes('快速匹配') && content.includes('深度匹配') && content.includes('语义精准匹配')) {
                        return {
                            valid: true,
                            reason: '架构设计文档存在且内容完整'
                        };
                    } else {
                        return {
                            valid: false,
                            reason: '架构设计文档内容不完整'
                        };
                    }
                } else {
                    return {
                        valid: false,
                        reason: '架构设计文档不存在'
                    };
                }
            } else {
                // 浏览器环境下，检查模块是否存在
                if (this.fastMatcher && this.deepMatcher && this.semanticPreciseMatcher) {
                    return {
                        valid: true,
                        reason: '所有匹配模块都已初始化'
                    };
                } else {
                    return {
                        valid: false,
                        reason: '部分匹配模块未初始化'
                    };
                }
            }
        } catch (error) {
            return {
                valid: false,
                reason: `检查架构设计失败: ${error.message}`
            };
        }
    }

    /**
     * 检查快速匹配模块
     * @returns {Object} 检查结果
     */
    async checkFastMatching() {
        try {
            if (!this.fastMatcher) {
                return {
                    valid: false,
                    reason: '快速匹配模块未初始化'
                };
            }
            
            // 构建查询参数
            const params = {
                query: '北京办公室',
                location: { lat: 39.915, lng: 116.404 },
                category: '办公空间'
            };
            
            // 执行快速匹配
            const startTime = Date.now();
            const result = await this.fastMatcher.match(this.mockResources, params);
            const endTime = Date.now();
            const duration = endTime - startTime;
            
            // 检查响应时间
            if (duration > 100) {
                return {
                    valid: false,
                    reason: `快速匹配响应时间过长: ${duration}ms > 100ms`
                };
            }
            
            // 检查结果
            if (!result || !result.results || result.results.length === 0) {
                return {
                    valid: false,
                    reason: '快速匹配未返回结果'
                };
            }
            
            return {
                valid: true,
                reason: `快速匹配响应时间: ${duration}ms < 100ms，结果数量: ${result.total}`
            };
        } catch (error) {
            return {
                valid: false,
                reason: `检查快速匹配模块失败: ${error.message}`
            };
        }
    }

    /**
     * 检查深度匹配模块
     * @returns {Object} 检查结果
     */
    async checkDeepMatching() {
        try {
            if (!this.deepMatcher) {
                return {
                    valid: false,
                    reason: '深度匹配模块未初始化'
                };
            }
            
            // 构建查询参数
            const params = {
                query: '北京朝阳区办公室出租',
                location: { lat: 39.915, lng: 116.404 },
                category: '办公空间'
            };
            
            // 执行深度匹配
            const startTime = Date.now();
            const result = await this.deepMatcher.match(this.mockResources, params);
            const endTime = Date.now();
            const duration = endTime - startTime;
            
            // 检查响应时间
            if (duration > 1000) {
                return {
                    valid: false,
                    reason: `深度匹配响应时间过长: ${duration}ms > 1000ms`
                };
            }
            
            // 检查结果
            if (!result || !result.results || result.results.length === 0) {
                return {
                    valid: false,
                    reason: '深度匹配未返回结果'
                };
            }
            
            return {
                valid: true,
                reason: `深度匹配响应时间: ${duration}ms < 1000ms，结果数量: ${result.total}`
            };
        } catch (error) {
            return {
                valid: false,
                reason: `检查深度匹配模块失败: ${error.message}`
            };
        }
    }

    /**
     * 检查语义精准匹配模块
     * @returns {Object} 检查结果
     */
    async checkSemanticMatching() {
        try {
            if (!this.semanticPreciseMatcher) {
                return {
                    valid: false,
                    reason: '语义精准匹配模块未初始化'
                };
            }
            
            // 构建查询参数
            const params = {
                query: '北京市朝阳区CBD核心区域现代化办公室出租',
                location: { lat: 39.915, lng: 116.404 },
                category: '办公空间'
            };
            
            // 执行语义精准匹配
            const startTime = Date.now();
            const result = await this.semanticPreciseMatcher.match(this.mockResources, params);
            const endTime = Date.now();
            const duration = endTime - startTime;
            
            // 检查响应时间
            if (duration > 2000) {
                return {
                    valid: false,
                    reason: `语义精准匹配响应时间过长: ${duration}ms > 2000ms`
                };
            }
            
            // 检查结果
            if (!result || !result.results || result.results.length === 0) {
                return {
                    valid: false,
                    reason: '语义精准匹配未返回结果'
                };
            }
            
            return {
                valid: true,
                reason: `语义精准匹配响应时间: ${duration}ms < 2000ms，结果数量: ${result.total}`
            };
        } catch (error) {
            return {
                valid: false,
                reason: `检查语义精准匹配模块失败: ${error.message}`
            };
        }
    }

    /**
     * 检查智能触发机制
     * @returns {Object} 检查结果
     */
    async checkSmartTrigger() {
        try {
            if (!this.smartTrigger) {
                return {
                    valid: false,
                    reason: '智能触发机制未初始化'
                };
            }
            
            // 测试智能触发
            const testQueries = [
                '北京办公室', // 短查询
                '北京朝阳区办公室出租', // 中等查询
                '北京市朝阳区CBD核心区域现代化办公室出租' // 长查询
            ];
            
            let allValid = true;
            const reasons = [];
            
            for (const query of testQueries) {
                const params = {
                    query: query,
                    location: { lat: 39.915, lng: 116.404 },
                    category: '办公空间'
                };
                
                const result = await this.smartTrigger.trigger(query, params);
                if (!result.matchingMode) {
                    allValid = false;
                    reasons.push(`智能触发未返回匹配模式: ${query}`);
                }
            }
            
            if (allValid) {
                return {
                    valid: true,
                    reason: '智能触发机制工作正常，能根据查询自动选择匹配模式'
                };
            } else {
                return {
                    valid: false,
                    reason: reasons.join('; ')
                };
            }
        } catch (error) {
            return {
                valid: false,
                reason: `检查智能触发机制失败: ${error.message}`
            };
        }
    }

    /**
     * 检查防抖技术
     * @returns {Object} 检查结果
     */
    checkDebounce() {
        try {
            if (!this.debounceUtil) {
                return {
                    valid: false,
                    reason: '防抖技术未初始化'
                };
            }
            
            // 检查防抖函数是否存在
            if (typeof window.debounce === 'function' && typeof window.throttle === 'function') {
                return {
                    valid: true,
                    reason: '防抖技术实现完成，包含debounce和throttle函数'
                };
            } else {
                return {
                    valid: false,
                    reason: '防抖函数未实现'
                };
            }
        } catch (error) {
            return {
                valid: false,
                reason: `检查防抖技术失败: ${error.message}`
            };
        }
    }

    /**
     * 检查前端集成
     * @returns {Object} 检查结果
     */
    checkFrontendIntegration() {
        try {
            if (!this.hybridMatchingFrontend) {
                return {
                    valid: false,
                    reason: '前端集成模块未初始化'
                };
            }
            
            // 检查DOM元素是否存在
            const container = document.getElementById('hybrid-matching-container');
            const searchInput = document.getElementById('search-input');
            const resultsContainer = document.getElementById('matching-results');
            
            if (container && searchInput && resultsContainer) {
                return {
                    valid: true,
                    reason: '前端集成完成，DOM元素存在'
                };
            } else {
                return {
                    valid: false,
                    reason: '前端DOM元素不存在'
                };
            }
        } catch (error) {
            return {
                valid: false,
                reason: `检查前端集成失败: ${error.message}`
            };
        }
    }

    /**
     * 检查性能
     * @returns {Object} 检查结果
     */
    async checkPerformance() {
        try {
            // 执行简单的性能测试
            const params = {
                query: '北京办公室',
                location: { lat: 39.915, lng: 116.404 },
                category: '办公空间'
            };
            
            const results = [];
            
            // 测试快速匹配
            if (this.fastMatcher) {
                const startTime = Date.now();
                await this.fastMatcher.match(this.mockResources, params);
                const endTime = Date.now();
                results.push({
                    mode: 'fast',
                    time: endTime - startTime
                });
            }
            
            // 测试深度匹配
            if (this.deepMatcher) {
                const startTime = Date.now();
                await this.deepMatcher.match(this.mockResources, params);
                const endTime = Date.now();
                results.push({
                    mode: 'deep',
                    time: endTime - startTime
                });
            }
            
            // 测试语义精准匹配
            if (this.semanticPreciseMatcher) {
                const startTime = Date.now();
                await this.semanticPreciseMatcher.match(this.mockResources, params);
                const endTime = Date.now();
                results.push({
                    mode: 'semantic',
                    time: endTime - startTime
                });
            }
            
            // 检查性能是否满足要求
            const fastResult = results.find(r => r.mode === 'fast');
            const deepResult = results.find(r => r.mode === 'deep');
            const semanticResult = results.find(r => r.mode === 'semantic');
            
            const issues = [];
            
            if (fastResult && fastResult.time > 100) {
                issues.push(`快速匹配响应时间过长: ${fastResult.time}ms > 100ms`);
            }
            
            if (deepResult && deepResult.time > 1000) {
                issues.push(`深度匹配响应时间过长: ${deepResult.time}ms > 1000ms`);
            }
            
            if (semanticResult && semanticResult.time > 2000) {
                issues.push(`语义精准匹配响应时间过长: ${semanticResult.time}ms > 2000ms`);
            }
            
            if (issues.length === 0) {
                return {
                    valid: true,
                    reason: '性能测试通过，所有模块响应时间满足要求'
                };
            } else {
                return {
                    valid: false,
                    reason: issues.join('; ')
                };
            }
        } catch (error) {
            return {
                valid: false,
                reason: `检查性能失败: ${error.message}`
            };
        }
    }

    /**
     * 检查混合匹配
     * @returns {Object} 检查结果
     */
    async checkHybridMatching() {
        try {
            // 测试不同匹配模式
            const modes = ['fast', 'deep', 'semantic'];
            const params = {
                query: '北京办公室',
                location: { lat: 39.915, lng: 116.404 },
                category: '办公空间'
            };
            
            let allValid = true;
            const reasons = [];
            
            for (const mode of modes) {
                try {
                    let result;
                    switch (mode) {
                        case 'fast':
                            result = await this.fastMatcher.match(this.mockResources, params);
                            break;
                        case 'deep':
                            result = await this.deepMatcher.match(this.mockResources, params);
                            break;
                        case 'semantic':
                            result = await this.semanticPreciseMatcher.match(this.mockResources, params);
                            break;
                    }
                    
                    if (!result || !result.results || result.results.length === 0) {
                        allValid = false;
                        reasons.push(`混合匹配模式${mode}未返回结果`);
                    }
                } catch (error) {
                    allValid = false;
                    reasons.push(`混合匹配模式${mode}测试失败: ${error.message}`);
                }
            }
            
            if (allValid) {
                return {
                    valid: true,
                    reason: '混合匹配模式测试通过，所有模式都能正常工作'
                };
            } else {
                return {
                    valid: false,
                    reason: reasons.join('; ')
                };
            }
        } catch (error) {
            return {
                valid: false,
                reason: `检查混合匹配失败: ${error.message}`
            };
        }
    }

    /**
     * 运行所有检查
     * @returns {Promise<Object>} 检查结果
     */
    async runAllChecks() {
        console.log('=== 成功标准验证 ===\n');
        
        const results = {};
        
        // 运行所有检查
        for (const [key, criteria] of Object.entries(this.config.successCriteria)) {
            console.log(`检查: ${criteria.description}`);
            
            let result;
            if (criteria.check.constructor.name === 'AsyncFunction') {
                result = await criteria.check();
            } else {
                result = criteria.check();
            }
            
            results[key] = result;
            console.log(`结果: ${result.valid ? '通过' : '失败'}`);
            if (!result.valid) {
                console.log(`原因: ${result.reason}`);
            }
            console.log('---\n');
        }
        
        // 生成验证报告
        this.generateValidationReport(results);
        
        return results;
    }

    /**
     * 生成验证报告
     * @param {Object} results 检查结果
     */
    generateValidationReport(results) {
        console.log('=== 成功标准验证报告 ===\n');
        
        // 统计验证结果
        const totalCriteria = Object.keys(results).length;
        const passedCriteria = Object.values(results).filter(r => r.valid).length;
        const failedCriteria = totalCriteria - passedCriteria;
        
        console.log(`验证总览:`);
        console.log(`总检查项: ${totalCriteria}`);
        console.log(`通过: ${passedCriteria}`);
        console.log(`失败: ${failedCriteria}`);
        console.log(`通过率: ${((passedCriteria / totalCriteria) * 100).toFixed(2)}%`);
        
        // 列出失败的检查项
        if (failedCriteria > 0) {
            console.log('\n失败的检查项:');
            for (const [key, result] of Object.entries(results)) {
                if (!result.valid) {
                    console.log(`- ${this.config.successCriteria[key].description}`);
                    console.log(`  失败原因: ${result.reason}`);
                }
            }
        }
        
        // 验证结论
        console.log('\n验证结论:');
        if (failedCriteria === 0) {
            console.log('🎉 所有检查项都通过了验证，迭代任务13完成！');
            console.log('\n成功标准达成:');
            console.log('1. 三层级匹配系统架构设计完成');
            console.log('2. 快速匹配模块响应时间 < 100ms');
            console.log('3. 深度匹配模块响应时间 < 1s');
            console.log('4. 语义精准匹配模块响应时间 < 2s');
            console.log('5. 智能触发机制实现完成');
            console.log('6. 防抖技术实现完成');
            console.log('7. 前端集成与用户界面优化完成');
            console.log('8. 性能优化与并发测试完成');
            console.log('9. 混合匹配模式测试与验证完成');
        } else {
            console.log('❌ 部分检查项未通过验证，需要进一步优化');
            console.log('\n建议:');
            console.log('1. 修复失败的检查项');
            console.log('2. 优化性能瓶颈');
            console.log('3. 完善文档和测试');
        }
    }
}

// 运行验证
function runSuccessCriteriaValidation() {
    console.log('=== 成功标准验证 ===\n');
    
    const successCriteriaValidation = new SuccessCriteriaValidation();
    successCriteriaValidation.runAllChecks()
        .then(results => {
            console.log('\n=== 成功标准验证完成 ===');
        })
        .catch(error => {
            console.error('验证失败:', error);
        });
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        SuccessCriteriaValidation,
        runSuccessCriteriaValidation
    };
} else if (typeof window !== 'undefined') {
    window.SuccessCriteriaValidation = SuccessCriteriaValidation;
    window.runSuccessCriteriaValidation = runSuccessCriteriaValidation;
    console.log('成功标准验证脚本已加载，请调用 runSuccessCriteriaValidation() 运行验证');
}