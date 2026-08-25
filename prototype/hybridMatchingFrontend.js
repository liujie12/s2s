/**
 * 混合匹配模式前端集成模块
 * 将所有匹配模块整合到前端界面中
 */
class HybridMatchingFrontend {
    /**
     * 构造函数
     * @param {Object} options 配置选项
     */
    constructor(options = {}) {
        this.config = {
            containerId: 'hybrid-matching-container',
            searchInputId: 'search-input',
            resultsContainerId: 'matching-results',
            modeSelectorId: 'matching-mode-selector',
            loadingId: 'loading-indicator',
            ...options
        };
        
        // 初始化模块
        this.initModules();
        
        // 初始化UI
        this.initUI();
        
        // 初始化事件监听器
        this.initEventListeners();
        
        // 初始化防抖处理
        this.initDebounce();
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
        
        // 导入工具
        this.debounceUtil = window.debounceUtil;
        this.debounce = window.debounce;
        
        // 模拟资源数据
        this.mockResources = [
            {
                id: '1',
                title: '北京朝阳区办公室出租',
                description: '位于朝阳区CBD核心区域，交通便利，配套齐全，适合中小型企业办公',
                category: '办公空间',
                tags: ['办公室', '出租', '朝阳区', 'CBD'],
                coordinates: [116.404, 39.915],
                price: '5000元/月',
                availableTime: '随时可用',
                rating: 4.8
            },
            {
                id: '2',
                title: '上海静安区商铺出租',
                description: '静安区繁华商圈，人流量大，适合各类零售业务',
                category: '商业空间',
                tags: ['商铺', '出租', '静安区', '商圈'],
                coordinates: [121.4737, 31.2304],
                price: '8000元/月',
                availableTime: '下周可用',
                rating: 4.5
            },
            {
                id: '3',
                title: '北京海淀区会议室出租',
                description: '海淀区中关村附近，现代化会议室，配备先进的会议设备',
                category: '办公空间',
                tags: ['会议室', '出租', '海淀区', '中关村'],
                coordinates: [116.305, 39.966],
                price: '2000元/天',
                availableTime: '随时可用',
                rating: 4.9
            },
            {
                id: '4',
                title: '北京东城区公寓出租',
                description: '东城区中心位置，交通便利，配套齐全，拎包入住',
                category: '住宅',
                tags: ['公寓', '出租', '东城区', '拎包入住'],
                coordinates: [116.416, 39.928],
                price: '6000元/月',
                availableTime: '随时可用',
                rating: 4.2
            },
            {
                id: '5',
                title: '北京西城区商铺出租',
                description: '西城区传统商圈，历史文化氛围浓厚，适合特色店铺',
                category: '商业空间',
                tags: ['商铺', '出租', '西城区', '特色店铺'],
                coordinates: [116.366, 39.912],
                price: '7000元/月',
                availableTime: '随时可用',
                rating: 4.6
            },
            {
                id: '6',
                title: '多功能铝合金梯子',
                description: '高强度铝合金材质，可折叠，适合家庭和专业使用',
                category: '工具设备',
                tags: ['梯子', '铝合金', '折叠', '多功能'],
                coordinates: [116.404, 39.915],
                price: '299元',
                availableTime: '随时可用',
                rating: 4.7
            },
            {
                id: '7',
                title: '伸缩梯',
                description: '可伸缩设计，高度调节方便，适合高空作业',
                category: '工具设备',
                tags: ['梯子', '伸缩', '高空作业', '工具'],
                coordinates: [116.305, 39.966],
                price: '499元',
                availableTime: '随时可用',
                rating: 4.8
            },
            {
                id: '8',
                title: '家用折叠梯',
                description: '轻便型家用折叠梯，适合日常家居使用',
                category: '工具设备',
                tags: ['梯子', '家用', '折叠', '轻便'],
                coordinates: [116.416, 39.928],
                price: '199元',
                availableTime: '随时可用',
                rating: 4.5
            }
        ];
    }

    /**
     * 初始化UI
     */
    initUI() {
        // 创建容器
        this.container = document.getElementById(this.config.containerId);
        if (!this.container) {
            this.container = document.createElement('div');
            this.container.id = this.config.containerId;
            this.container.className = 'hybrid-matching-container';
            // 查找phone-frame元素，将容器添加到其中，避免遮挡地图
            const phoneFrame = document.querySelector('.phone-frame');
            if (phoneFrame) {
                phoneFrame.appendChild(this.container);
            } else {
                document.body.appendChild(this.container);
            }
        }
        
        // 构建UI（不包含搜索输入框，使用index.html中已有的）
        this.container.innerHTML = `
            <div class="hybrid-matching-header">
                <h2>智能资源匹配</h2>
                <div class="mode-section">
                    <label for="${this.config.modeSelectorId}">匹配模式：</label>
                    <select id="${this.config.modeSelectorId}" class="mode-selector">
                        <option value="auto">智能模式</option>
                        <option value="fast">快速匹配</option>
                        <option value="deep">深度匹配</option>
                        <option value="semantic">语义精准匹配</option>
                    </select>
                </div>
            </div>
            <div id="${this.config.loadingId}" class="loading-indicator" style="display: none;">
                <div class="loading-spinner"></div>
                <p>正在匹配中...</p>
            </div>
            <div id="${this.config.resultsContainerId}" class="matching-results">
                <p class="no-results">请输入您的需求并点击搜索按钮</p>
            </div>
        `;
        
        // 添加样式
        this.addStyles();
    }

    /**
     * 添加样式
     */
    addStyles() {
        const style = document.createElement('style');
        style.textContent = `
            .hybrid-matching-container {
                max-width: 100%;
                margin: 0;
                padding: 10px;
                font-family: Arial, sans-serif;
                background: white;
                border-radius: 10px;
                box-shadow: 0 2px 10px rgba(0,0,0,0.1);
                margin: 10px;
                position: relative;
                z-index: 10;
            }
            
            .hybrid-matching-header {
                margin-bottom: 30px;
            }
            
            .hybrid-matching-header h2 {
                color: #333;
                font-size: 24px;
                margin-bottom: 20px;
            }
            
            .search-section {
                display: flex;
                margin-bottom: 20px;
            }
            
            .search-input {
                flex: 1;
                padding: 12px 16px;
                font-size: 16px;
                border: 2px solid #ddd;
                border-radius: 4px 0 0 4px;
                outline: none;
                transition: border-color 0.3s ease;
            }
            
            .search-input:focus {
                border-color: #4CAF50;
            }
            
            .search-button {
                padding: 0 24px;
                font-size: 16px;
                background-color: #4CAF50;
                color: white;
                border: none;
                border-radius: 0 4px 4px 0;
                cursor: pointer;
                transition: background-color 0.3s ease;
            }
            
            .search-button:hover {
                background-color: #45a049;
            }
            
            .mode-section {
                display: flex;
                align-items: center;
                margin-bottom: 20px;
            }
            
            .mode-section label {
                margin-right: 10px;
                font-size: 14px;
                color: #666;
            }
            
            .mode-selector {
                padding: 8px 12px;
                font-size: 14px;
                border: 1px solid #ddd;
                border-radius: 4px;
                outline: none;
                background-color: white;
            }
            
            .loading-indicator {
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                padding: 40px 0;
            }
            
            .loading-spinner {
                border: 4px solid #f3f3f3;
                border-top: 4px solid #4CAF50;
                border-radius: 50%;
                width: 40px;
                height: 40px;
                animation: spin 1s linear infinite;
                margin-bottom: 16px;
            }
            
            @keyframes spin {
                0% { transform: rotate(0deg); }
                100% { transform: rotate(360deg); }
            }
            
            .matching-results {
                margin-top: 20px;
            }
            
            .no-results {
                text-align: center;
                color: #999;
                padding: 40px 0;
            }
            
            .result-item {
                background-color: white;
                border: 1px solid #ddd;
                border-radius: 8px;
                padding: 20px;
                margin-bottom: 16px;
                box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
                transition: transform 0.3s ease, box-shadow 0.3s ease;
            }
            
            .result-item:hover {
                transform: translateY(-2px);
                box-shadow: 0 4px 8px rgba(0, 0, 0, 0.15);
            }
            
            .result-title {
                font-size: 18px;
                font-weight: bold;
                color: #333;
                margin-bottom: 8px;
            }
            
            .result-description {
                font-size: 14px;
                color: #666;
                margin-bottom: 12px;
                line-height: 1.4;
            }
            
            .result-meta {
                display: flex;
                flex-wrap: wrap;
                gap: 12px;
                margin-bottom: 12px;
                font-size: 14px;
            }
            
            .result-meta-item {
                display: flex;
                align-items: center;
                color: #888;
            }
            
            .result-meta-item strong {
                color: #555;
                margin-right: 4px;
            }
            
            .result-score {
                margin-top: 12px;
                padding-top: 12px;
                border-top: 1px solid #eee;
            }
            
            .score-item {
                display: flex;
                justify-content: space-between;
                margin-bottom: 4px;
                font-size: 14px;
            }
            
            .score-label {
                color: #666;
            }
            
            .score-value {
                font-weight: bold;
                color: #4CAF50;
            }
            
            .result-actions {
                margin-top: 16px;
                display: flex;
                gap: 12px;
            }
            
            .action-button {
                padding: 8px 16px;
                font-size: 14px;
                border: none;
                border-radius: 4px;
                cursor: pointer;
                transition: background-color 0.3s ease;
            }
            
            .action-button.primary {
                background-color: #4CAF50;
                color: white;
            }
            
            .action-button.primary:hover {
                background-color: #45a049;
            }
            
            .action-button.secondary {
                background-color: #f0f0f0;
                color: #333;
            }
            
            .action-button.secondary:hover {
                background-color: #e0e0e0;
            }
            
            @media (max-width: 768px) {
                .hybrid-matching-container {
                    padding: 10px;
                }
                
                .search-section {
                    flex-direction: column;
                }
                
                .search-input {
                    border-radius: 4px;
                    margin-bottom: 10px;
                }
                
                .search-button {
                    border-radius: 4px;
                    padding: 12px;
                }
                
                .mode-section {
                    flex-direction: column;
                    align-items: flex-start;
                }
                
                .mode-section label {
                    margin-bottom: 8px;
                }
            }
        `;
        
        document.head.appendChild(style);
    }

    /**
     * 初始化事件监听器
     */
    initEventListeners() {
        // 获取元素
        this.searchInput = document.getElementById(this.config.searchInputId);
        // 尝试获取index.html中已有的搜索输入框
        if (!this.searchInput) {
            this.searchInput = document.getElementById('search-input');
        }
        this.searchButton = document.querySelector('.search-button');
        // 尝试获取index.html中已有的搜索按钮
        if (!this.searchButton) {
            this.searchButton = document.querySelector('.search-btn');
        }
        this.modeSelector = document.getElementById(this.config.modeSelectorId);
        this.resultsContainer = document.getElementById(this.config.resultsContainerId);
        this.loadingIndicator = document.getElementById(this.config.loadingId);
        
        // 搜索按钮点击事件
        if (this.searchButton) {
            this.searchButton.addEventListener('click', () => {
                this.performSearch();
            });
        }
        
        // 搜索输入框回车事件
        if (this.searchInput) {
            this.searchInput.addEventListener('keypress', (e) => {
                if (e.key === 'Enter') {
                    this.performSearch();
                }
            });
        }
        
        // 匹配模式选择事件
        if (this.modeSelector) {
            this.modeSelector.addEventListener('change', (e) => {
                let query = '';
                if (this.searchInput) {
                    query = this.searchInput.value.trim();
                }
                if (query) {
                    this.performSearch();
                }
            });
        }
    }

    /**
     * 初始化防抖处理
     */
    initDebounce() {
        // 为搜索输入添加防抖处理
        if (this.searchInput) {
            const debouncedSearch = this.debounce(() => {
                const query = this.searchInput.value.trim();
                if (query.length >= 2) {
                    this.performSearch();
                }
            }, 500);
            
            this.searchInput.addEventListener('input', debouncedSearch);
        }
    }

    /**
     * 防抖函数
     * @param {Function} func 要执行的函数
     * @param {number} delay 延迟时间
     * @returns {Function} 防抖处理后的函数
     */
    debounce(func, delay = 300) {
        let timeoutId;
        
        return function(...args) {
            clearTimeout(timeoutId);
            timeoutId = setTimeout(() => {
                func.apply(this, args);
            }, delay);
        };
    }

    /**
     * 执行搜索
     */
    async performSearch() {
        // 获取搜索输入框的值
        let query = '';
        if (this.searchInput) {
            query = this.searchInput.value.trim();
        } else {
            // 尝试获取index.html中已有的搜索输入框
            const mainSearchInput = document.getElementById('search-input');
            if (mainSearchInput) {
                query = mainSearchInput.value.trim();
            }
        }
        
        if (!query) {
            this.showMessage('请输入您的需求', 'warning');
            return;
        }
        
        // 显示加载状态
        this.showLoading(true);
        
        try {
            // 获取选择的匹配模式
            const selectedMode = this.modeSelector.value;
            
            // 构建查询参数
            const params = {
                query,
                location: { lat: 39.915, lng: 116.404 }, // 默认位置（北京）
                category: 'all',
                budget: null,
                time: '随时'
            };
            
            let results;
            
            // 根据选择的模式执行匹配
            if (selectedMode === 'auto') {
                // 智能模式：使用智能触发机制
                results = await this.executeAutoMatching(params);
            } else if (selectedMode === 'fast') {
                // 快速匹配
                results = await this.executeFastMatching(params);
            } else if (selectedMode === 'deep') {
                // 深度匹配
                results = await this.executeDeepMatching(params);
            } else if (selectedMode === 'semantic') {
                // 语义精准匹配
                results = await this.executeSemanticMatching(params);
            }
            
            // 显示结果
            this.displayResults(results);
        } catch (error) {
            console.error('搜索失败:', error);
            this.showMessage('搜索失败，请重试', 'error');
        } finally {
            // 隐藏加载状态
            this.showLoading(false);
        }
    }

    /**
     * 执行智能匹配
     * @param {Object} params 查询参数
     * @returns {Object} 匹配结果
     */
    async executeAutoMatching(params) {
        if (!this.smartTrigger) {
            console.warn('智能触发模块未初始化，使用默认的深度匹配模式');
            return this.executeDeepMatching(params);
        }
        
        try {
            // 使用智能触发机制选择匹配模式
            const triggerResult = await this.smartTrigger.trigger(params.query, params);
            
            // 根据选择的模式执行匹配
            switch (triggerResult.matchingMode) {
                case 'fast':
                    return this.executeFastMatching(params);
                case 'deep':
                    return this.executeDeepMatching(params);
                case 'full':
                    return this.executeSemanticMatching(params);
                default:
                    return this.executeDeepMatching(params);
            }
        } catch (error) {
            console.error('智能触发执行失败:', error);
            return this.executeDeepMatching(params);
        }
    }

    /**
     * 执行快速匹配
     * @param {Object} params 查询参数
     * @returns {Object} 匹配结果
     */
    async executeFastMatching(params) {
        if (!this.fastMatcher) {
            throw new Error('快速匹配模块未初始化');
        }
        
        const result = await this.fastMatcher.match(this.mockResources, params);
        
        return {
            ...result,
            mode: 'fast'
        };
    }

    /**
     * 执行深度匹配
     * @param {Object} params 查询参数
     * @returns {Object} 匹配结果
     */
    async executeDeepMatching(params) {
        if (!this.deepMatcher) {
            throw new Error('深度匹配模块未初始化');
        }
        
        const result = await this.deepMatcher.match(this.mockResources, params);
        
        return {
            ...result,
            mode: 'deep'
        };
    }

    /**
     * 执行语义精准匹配
     * @param {Object} params 查询参数
     * @returns {Object} 匹配结果
     */
    async executeSemanticMatching(params) {
        if (!this.semanticPreciseMatcher) {
            throw new Error('语义精准匹配模块未初始化');
        }
        
        const result = await this.semanticPreciseMatcher.match(this.mockResources, params);
        
        return {
            ...result,
            mode: 'semantic'
        };
    }

    /**
     * 显示加载状态
     * @param {boolean} show 是否显示
     */
    showLoading(show) {
        if (this.loadingIndicator) {
            this.loadingIndicator.style.display = show ? 'flex' : 'none';
        }
    }

    /**
     * 显示消息
     * @param {string} message 消息内容
     * @param {string} type 消息类型
     */
    showMessage(message, type = 'info') {
        // 创建消息元素
        const messageElement = document.createElement('div');
        messageElement.className = `message ${type}`;
        messageElement.textContent = message;
        
        // 添加样式
        messageElement.style.cssText = `
            padding: 12px;
            margin: 10px 0;
            border-radius: 4px;
            text-align: center;
            font-size: 14px;
            animation: fadeIn 0.3s ease;
        `;
        
        // 根据类型设置样式
        switch (type) {
            case 'error':
                messageElement.style.backgroundColor = '#ffebee';
                messageElement.style.color = '#c62828';
                break;
            case 'warning':
                messageElement.style.backgroundColor = '#fff3e0';
                messageElement.style.color = '#ef6c00';
                break;
            case 'success':
                messageElement.style.backgroundColor = '#e8f5e8';
                messageElement.style.color = '#2e7d32';
                break;
            default:
                messageElement.style.backgroundColor = '#e3f2fd';
                messageElement.style.color = '#1565c0';
        }
        
        // 添加到容器
        this.container.insertBefore(messageElement, this.container.firstChild);
        
        // 3秒后移除
        setTimeout(() => {
            messageElement.style.animation = 'fadeOut 0.3s ease';
            setTimeout(() => {
                if (messageElement.parentNode) {
                    messageElement.parentNode.removeChild(messageElement);
                }
            }, 300);
        }, 3000);
    }

    /**
     * 显示结果
     * @param {Object} result 匹配结果
     */
    displayResults(result) {
        if (!this.resultsContainer) {
            return;
        }
        
        if (!result || !result.results || result.results.length === 0) {
            this.resultsContainer.innerHTML = `
                <p class="no-results">未找到匹配的结果，请尝试调整搜索条件</p>
            `;
            // 更新地图标记点（清空）
            this.updateMapMarkers([]);
            return;
        }
        
        // 生成结果HTML
        const resultsHTML = result.results.map(item => {
            return `
                <div class="result-item">
                    <h3 class="result-title">${item.title}</h3>
                    <p class="result-description">${item.description}</p>
                    <div class="result-meta">
                        <div class="result-meta-item">
                            <strong>分类：</strong>${item.category}
                        </div>
                        <div class="result-meta-item">
                            <strong>位置：</strong>${item.tags && item.tags.length ? item.tags.join(', ') : '未知'}
                        </div>
                        <div class="result-meta-item">
                            <strong>价格：</strong>${item.price}
                        </div>
                        <div class="result-meta-item">
                            <strong>可用时间：</strong>${item.availableTime}
                        </div>
                        <div class="result-meta-item">
                            <strong>评分：</strong>${item.rating}
                        </div>
                    </div>
                    <div class="result-score">
                        ${item.score !== undefined ? `
                            <div class="score-item">
                                <span class="score-label">匹配得分：</span>
                                <span class="score-value">${item.score.toFixed(2)}</span>
                            </div>
                        ` : ''}
                        ${item.semanticScore !== undefined ? `
                            <div class="score-item">
                                <span class="score-label">语义相似度：</span>
                                <span class="score-value">${item.semanticScore.toFixed(2)}</span>
                            </div>
                        ` : ''}
                        ${item.distanceScore !== undefined ? `
                            <div class="score-item">
                                <span class="score-label">距离得分：</span>
                                <span class="score-value">${item.distanceScore.toFixed(2)}</span>
                            </div>
                        ` : ''}
                        ${item.categoryScore !== undefined ? `
                            <div class="score-item">
                                <span class="score-label">分类得分：</span>
                                <span class="score-value">${item.categoryScore.toFixed(2)}</span>
                            </div>
                        ` : ''}
                        ${item.priceScore !== undefined ? `
                            <div class="score-item">
                                <span class="score-label">价格得分：</span>
                                <span class="score-value">${item.priceScore.toFixed(2)}</span>
                            </div>
                        ` : ''}
                    </div>
                    ${item.semanticMatchReasons && item.semanticMatchReasons.length ? `
                        <div class="result-reasons">
                            <h4>匹配原因：</h4>
                            <ul>
                                ${item.semanticMatchReasons.map(reason => `<li>${reason}</li>`).join('')}
                            </ul>
                        </div>
                    ` : ''}
                    <div class="result-actions">
                        <button class="action-button primary">查看详情</button>
                        <button class="action-button secondary">收藏</button>
                        <button class="action-button secondary">联系</button>
                    </div>
                </div>
            `;
        }).join('');
        
        // 更新结果容器
        this.resultsContainer.innerHTML = `
            <div class="results-header">
                <h3>匹配结果 (${result.total} 个)</h3>
                <p class="results-info">
                    匹配模式：${this.getModeName(result.mode)} | 
                    响应时间：${result.time}ms
                </p>
            </div>
            <div class="results-list">
                ${resultsHTML}
            </div>
        `;
        
        // 更新地图标记点
        this.updateMapMarkers(result.results);
        
        // 添加结果样式
        this.addResultsStyles();
    }

    /**
     * 更新地图标记点
     * @param {Array} results 搜索结果
     */
    updateMapMarkers(results) {
        console.log('更新地图标记点，结果数量：', results.length);
        
        // 检查是否存在全局地图对象和标记数组
        if (typeof window.map !== 'undefined' && window.map !== null && typeof window.markers !== 'undefined') {
            console.log('地图已初始化，开始更新标记点');
            
            // 清除现有标记
            window.markers.forEach(marker => {
                if (marker.setMap) {
                    marker.setMap(null);
                }
            });
            window.markers = [];
            
            // 为每个搜索结果创建标记点
            results.forEach((item, index) => {
                // 生成随机位置（实际应用中应该使用真实的经纬度）
                const lng = 116.397428 + (Math.random() - 0.5) * 0.05;
                const lat = 39.90923 + (Math.random() - 0.5) * 0.05;
                
                // 根据分类设置图标
                let icon = '📦';
                if (item.category.includes('梯子') || item.title.includes('梯')) {
                    icon = '🪜';
                } else if (item.category.includes('工具')) {
                    icon = '🔧';
                } else if (item.category.includes('服务')) {
                    icon = '👨‍🔧';
                }
                
                // 检查是否存在AMap对象
                if (typeof AMap !== 'undefined') {
                    // 创建自定义标记
                    const marker = new AMap.Marker({
                        position: [lng, lat],
                        map: window.map,
                        title: item.title,
                        content: `<div style="width:40px;height:40px;border-radius:50%;background:#4CAF50;display:flex;align-items:center;justify-content:center;font-size:20px;box-shadow:0 2px 8px rgba(0,0,0,0.2);border:3px solid white;">${icon}</div>`,
                        extData: item // 存储额外数据
                    });
                    
                    // 添加点击事件
                    marker.on('click', function() {
                        console.log('点击标记:', item.title);
                        // 这里可以添加显示详情的逻辑
                    });
                    
                    window.markers.push(marker);
                } else {
                    console.log('AMap对象未定义，无法创建标记点');
                }
            });
            
            console.log('完成更新地图标记点，共添加', window.markers.length, '个点位');
        } else {
            console.log('地图未初始化，尝试初始化地图');
            // 尝试初始化地图
            if (typeof window.initMap !== 'undefined') {
                window.initMap();
                // 保存当前实例的引用
                const self = this;
                // 延迟一下，确保地图初始化完成
                setTimeout(() => {
                    self.updateMapMarkers(results);
                }, 2000);
            } else {
                console.log('initMap函数未定义，无法初始化地图');
            }
        }
    }

    /**
     * 添加结果样式
     */
    addResultsStyles() {
        const style = document.createElement('style');
        style.textContent = `
            .results-header {
                margin-bottom: 20px;
                padding-bottom: 12px;
                border-bottom: 2px solid #4CAF50;
            }
            
            .results-header h3 {
                font-size: 18px;
                color: #333;
                margin-bottom: 8px;
            }
            
            .results-info {
                font-size: 14px;
                color: #888;
                margin: 0;
            }
            
            .results-list {
                display: flex;
                flex-direction: column;
                gap: 16px;
            }
            
            .result-reasons {
                margin-top: 12px;
                padding: 12px;
                background-color: #f9f9f9;
                border-radius: 4px;
            }
            
            .result-reasons h4 {
                font-size: 14px;
                font-weight: bold;
                color: #555;
                margin-bottom: 8px;
            }
            
            .result-reasons ul {
                margin: 0;
                padding-left: 20px;
                font-size: 14px;
                color: #666;
            }
            
            .result-reasons li {
                margin-bottom: 4px;
            }
            
            @keyframes fadeIn {
                from { opacity: 0; transform: translateY(-10px); }
                to { opacity: 1; transform: translateY(0); }
            }
            
            @keyframes fadeOut {
                from { opacity: 1; transform: translateY(0); }
                to { opacity: 0; transform: translateY(-10px); }
            }
        `;
        
        document.head.appendChild(style);
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
        
        return modeNames[mode] || '未知模式';
    }
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = HybridMatchingFrontend;
} else if (typeof window !== 'undefined') {
    window.HybridMatchingFrontend = HybridMatchingFrontend;
}