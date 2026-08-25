/**
 * 多源定位融合功能测试脚本
 * 测试各种场景下的定位功能准确性和可靠性
 */

// 导入多源定位服务
let multiSourceLocationService;
let MultiSourceLocationService;

if (typeof window !== 'undefined') {
    // 浏览器环境
    multiSourceLocationService = window.multiSourceLocationService;
    MultiSourceLocationService = multiSourceLocationService.MultiSourceLocationService;
} else {
    // Node.js环境
    const moduleExports = require('./multiSourceLocation');
    multiSourceLocationService = moduleExports;
    MultiSourceLocationService = moduleExports.MultiSourceLocationService;
}

/**
 * 多源定位融合测试套件
 */
class MultiSourceLocationTestSuite {
    constructor() {
        this.locationService = new MultiSourceLocationService();
        this.testResults = [];
        this.testCount = 0;
        this.passedTests = 0;
        this.failedTests = 0;
    }

    /**
     * 运行所有测试
     */
    async runAllTests() {
        console.log('开始多源定位融合功能测试...');
        console.log('==================================');

        // 运行各个测试用例
        await this.testNormalLocation();
        await this.testLocationWithAccuracyRequirement();
        await this.testPartialSourceFailure();
        await this.testErrorRecovery();
        await this.testCacheUsage();
        await this.testDynamicPriorityAdjustment();
        await this.testAccuracyAssessment();

        // 输出测试结果
        this.printTestResults();
    }

    /**
     * 测试正常定位场景
     */
    async testNormalLocation() {
        const testName = '正常定位测试';
        this.testCount++;

        try {
            console.log(`\n测试: ${testName}`);
            console.log('测试描述: 测试正常情况下的定位融合功能');

            const startTime = Date.now();
            const location = await this.locationService.getFusedLocation({
                timeout: 5000
            });
            const responseTime = Date.now() - startTime;

            console.log(`响应时间: ${responseTime}ms`);
            console.log(`定位结果:`, location);

            // 验证定位结果
            const isValid = this._validateLocationResult(location);

            if (isValid) {
                console.log('✅ 测试通过');
                this.passedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'passed',
                    responseTime: responseTime,
                    accuracy: location.accuracy,
                    confidence: location.confidence
                });
            } else {
                console.log('❌ 测试失败: 定位结果无效');
                this.failedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'failed',
                    error: '定位结果无效'
                });
            }
        } catch (error) {
            console.log(`❌ 测试失败: ${error.message}`);
            this.failedTests++;
            this.testResults.push({
                name: testName,
                status: 'failed',
                error: error.message
            });
        }
    }

    /**
     * 测试带精度要求的定位
     */
    async testLocationWithAccuracyRequirement() {
        const testName = '精度要求测试';
        this.testCount++;

        try {
            console.log(`\n测试: ${testName}`);
            console.log('测试描述: 测试带最小精度要求的定位功能');

            const startTime = Date.now();
            const location = await this.locationService.getFusedLocation({
                timeout: 5000,
                minAccuracy: 100 // 要求精度在100米以内
            });
            const responseTime = Date.now() - startTime;

            console.log(`响应时间: ${responseTime}ms`);
            console.log(`定位结果:`, location);

            // 验证定位结果
            const isValid = this._validateLocationResult(location);
            const meetsAccuracy = location.accuracyAssessment && location.accuracyAssessment.meetsAccuracyRequirement;

            if (isValid && meetsAccuracy) {
                console.log('✅ 测试通过');
                this.passedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'passed',
                    responseTime: responseTime,
                    accuracy: location.accuracy,
                    meetsAccuracy: meetsAccuracy
                });
            } else {
                console.log(`❌ 测试失败: 定位结果无效或不满足精度要求`);
                this.failedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'failed',
                    error: '定位结果无效或不满足精度要求'
                });
            }
        } catch (error) {
            console.log(`❌ 测试失败: ${error.message}`);
            this.failedTests++;
            this.testResults.push({
                name: testName,
                status: 'failed',
                error: error.message
            });
        }
    }

    /**
     * 测试部分定位源失败的场景
     */
    async testPartialSourceFailure() {
        const testName = '部分定位源失败测试';
        this.testCount++;

        try {
            console.log(`\n测试: ${testName}`);
            console.log('测试描述: 测试部分定位源失败时的定位融合功能');

            // 模拟部分定位源失败
            const originalGetLocation = this.locationService.locationSources[0].getLocation;
            this.locationService.locationSources[0].getLocation = async () => {
                throw new Error('模拟定位源失败');
            };

            const startTime = Date.now();
            const location = await this.locationService.getFusedLocation({
                timeout: 5000
            });
            const responseTime = Date.now() - startTime;

            // 恢复原始方法
            this.locationService.locationSources[0].getLocation = originalGetLocation;

            console.log(`响应时间: ${responseTime}ms`);
            console.log(`定位结果:`, location);

            // 验证定位结果
            const isValid = this._validateLocationResult(location);

            if (isValid) {
                console.log('✅ 测试通过');
                this.passedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'passed',
                    responseTime: responseTime,
                    accuracy: location.accuracy
                });
            } else {
                console.log('❌ 测试失败: 定位结果无效');
                this.failedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'failed',
                    error: '定位结果无效'
                });
            }
        } catch (error) {
            console.log(`❌ 测试失败: ${error.message}`);
            this.failedTests++;
            this.testResults.push({
                name: testName,
                status: 'failed',
                error: error.message
            });
        }
    }

    /**
     * 测试错误恢复功能
     */
    async testErrorRecovery() {
        const testName = '错误恢复测试';
        this.testCount++;

        try {
            console.log(`\n测试: ${testName}`);
            console.log('测试描述: 测试错误恢复功能');

            // 模拟所有定位源失败
            const originalGetLocationMethods = [];
            for (let i = 0; i < this.locationService.locationSources.length; i++) {
                originalGetLocationMethods[i] = this.locationService.locationSources[i].getLocation;
                this.locationService.locationSources[i].getLocation = async () => {
                    throw new Error('模拟定位源失败');
                };
            }

            // 先获取一个缓存位置
            const cacheLocation = await this.locationService.getFusedLocation({
                timeout: 5000
            });

            // 然后模拟所有定位源失败
            for (let i = 0; i < this.locationService.locationSources.length; i++) {
                this.locationService.locationSources[i].getLocation = async () => {
                    throw new Error('模拟定位源失败');
                };
            }

            const startTime = Date.now();
            const location = await this.locationService.getFusedLocation({
                timeout: 5000,
                enableErrorRecovery: true
            });
            const responseTime = Date.now() - startTime;

            // 恢复原始方法
            for (let i = 0; i < this.locationService.locationSources.length; i++) {
                this.locationService.locationSources[i].getLocation = originalGetLocationMethods[i];
            }

            console.log(`响应时间: ${responseTime}ms`);
            console.log(`定位结果:`, location);

            // 验证定位结果
            const isValid = this._validateLocationResult(location);
            const isRecovered = location.errorRecovered || location.fromCache;

            if (isValid && isRecovered) {
                console.log('✅ 测试通过');
                this.passedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'passed',
                    responseTime: responseTime,
                    isRecovered: isRecovered
                });
            } else {
                console.log('❌ 测试失败: 错误恢复失败');
                this.failedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'failed',
                    error: '错误恢复失败'
                });
            }
        } catch (error) {
            console.log(`❌ 测试失败: ${error.message}`);
            this.failedTests++;
            this.testResults.push({
                name: testName,
                status: 'failed',
                error: error.message
            });
        }
    }

    /**
     * 测试缓存使用
     */
    async testCacheUsage() {
        const testName = '缓存使用测试';
        this.testCount++;

        try {
            console.log(`\n测试: ${testName}`);
            console.log('测试描述: 测试缓存使用功能');

            // 清空缓存
            this.locationService.clearCache();

            // 第一次获取位置（应该不使用缓存）
            const location1 = await this.locationService.getFusedLocation({
                timeout: 5000
            });
            console.log('第一次定位结果（不使用缓存）:', location1);

            // 第二次获取位置（应该使用缓存）
            const location2 = await this.locationService.getFusedLocation({
                timeout: 5000
            });
            console.log('第二次定位结果（应该使用缓存）:', location2);

            // 验证缓存使用
            const isFromCache = location2.fromCache === true;

            if (isFromCache) {
                console.log('✅ 测试通过');
                this.passedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'passed',
                    isFromCache: isFromCache
                });
            } else {
                console.log('❌ 测试失败: 缓存未使用');
                this.failedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'failed',
                    error: '缓存未使用'
                });
            }
        } catch (error) {
            console.log(`❌ 测试失败: ${error.message}`);
            this.failedTests++;
            this.testResults.push({
                name: testName,
                status: 'failed',
                error: error.message
            });
        }
    }

    /**
     * 测试动态优先级调整
     */
    async testDynamicPriorityAdjustment() {
        const testName = '动态优先级调整测试';
        this.testCount++;

        try {
            console.log(`\n测试: ${testName}`);
            console.log('测试描述: 测试动态优先级调整功能');

            // 触发多次定位以积累历史数据
            for (let i = 0; i < 5; i++) {
                await this.locationService.getFusedLocation({
                    timeout: 5000
                });
                console.log(`完成第 ${i + 1} 次定位`);
            }

            // 检查动态优先级调整是否生效
            const healthStatus = this.locationService.sourceHealthStatus;
            console.log('定位源健康状态:', healthStatus);

            // 验证健康状态数据
            const hasHealthData = healthStatus.size > 0;

            if (hasHealthData) {
                console.log('✅ 测试通过');
                this.passedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'passed',
                    healthDataCount: healthStatus.size
                });
            } else {
                console.log('❌ 测试失败: 健康状态数据为空');
                this.failedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'failed',
                    error: '健康状态数据为空'
                });
            }
        } catch (error) {
            console.log(`❌ 测试失败: ${error.message}`);
            this.failedTests++;
            this.testResults.push({
                name: testName,
                status: 'failed',
                error: error.message
            });
        }
    }

    /**
     * 测试精度评估功能
     */
    async testAccuracyAssessment() {
        const testName = '精度评估测试';
        this.testCount++;

        try {
            console.log(`\n测试: ${testName}`);
            console.log('测试描述: 测试精度评估功能');

            const location = await this.locationService.getFusedLocation({
                timeout: 5000,
                minAccuracy: 100
            });

            console.log('定位结果:', location);

            // 验证精度评估
            const hasAccuracyAssessment = location.accuracyAssessment !== undefined;
            const isValidAssessment = hasAccuracyAssessment && 
                location.accuracyAssessment.accuracyLevel !== undefined &&
                location.accuracyAssessment.reliability !== undefined;

            if (isValidAssessment) {
                console.log('✅ 测试通过');
                this.passedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'passed',
                    accuracyLevel: location.accuracyAssessment.accuracyLevel,
                    reliability: location.accuracyAssessment.reliability
                });
            } else {
                console.log('❌ 测试失败: 精度评估无效');
                this.failedTests++;
                this.testResults.push({
                    name: testName,
                    status: 'failed',
                    error: '精度评估无效'
                });
            }
        } catch (error) {
            console.log(`❌ 测试失败: ${error.message}`);
            this.failedTests++;
            this.testResults.push({
                name: testName,
                status: 'failed',
                error: error.message
            });
        }
    }

    /**
     * 验证定位结果
     * @param {Object} location - 定位结果
     * @returns {boolean} 是否有效
     * @private
     */
    _validateLocationResult(location) {
        if (!location) {
            return false;
        }

        if (typeof location.latitude !== 'number' || typeof location.longitude !== 'number') {
            return false;
        }

        if (typeof location.accuracy !== 'number' || location.accuracy <= 0) {
            return false;
        }

        if (typeof location.timestamp !== 'number') {
            return false;
        }

        return true;
    }

    /**
     * 打印测试结果
     */
    printTestResults() {
        console.log('\n==================================');
        console.log('多源定位融合功能测试结果');
        console.log('==================================');
        console.log(`总测试数: ${this.testCount}`);
        console.log(`通过测试: ${this.passedTests}`);
        console.log(`失败测试: ${this.failedTests}`);
        console.log(`测试通过率: ${((this.passedTests / this.testCount) * 100).toFixed(2)}%`);
        console.log('==================================');

        // 打印详细测试结果
        console.log('\n详细测试结果:');
        this.testResults.forEach((result, index) => {
            console.log(`\n${index + 1}. ${result.name}`);
            console.log(`   状态: ${result.status}`);
            if (result.status === 'passed') {
                if (result.responseTime) {
                    console.log(`   响应时间: ${result.responseTime}ms`);
                }
                if (result.accuracy) {
                    console.log(`   精度: ${result.accuracy.toFixed(2)}m`);
                }
                if (result.confidence) {
                    console.log(`   置信度: ${(result.confidence * 100).toFixed(2)}%`);
                }
                if (result.isFromCache !== undefined) {
                    console.log(`   使用缓存: ${result.isFromCache}`);
                }
                if (result.isRecovered !== undefined) {
                    console.log(`   错误恢复: ${result.isRecovered}`);
                }
            } else {
                console.log(`   错误: ${result.error}`);
            }
        });

        console.log('\n==================================');
        console.log('测试完成');
        console.log('==================================');
    }
}

// 运行测试
if (typeof window !== 'undefined') {
    // 浏览器环境
    window.multiSourceLocationTest = {
        MultiSourceLocationTestSuite,
        runTests: async () => {
            const testSuite = new MultiSourceLocationTestSuite();
            await testSuite.runAllTests();
        }
    };
    
    console.log('多源定位融合测试套件已加载');
    console.log('运行测试: window.multiSourceLocationTest.runTests()');
} else {
    // Node.js环境
    module.exports = {
        MultiSourceLocationTestSuite
    };
}
