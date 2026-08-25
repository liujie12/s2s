/**
 * 智能解析服务模块
 * 集成通义千问大模型智能解析服务接口，支持通过大模型对资源/需求描述进行智能解析
 * 将自然语言转换为结构化数据，包括行业特定解析模板和标签自动生成
 */

class SmartParseService {
  /**
   * 构造函数
   */
  constructor() {
    // 通义千问API配置
    this.apiConfig = {
      // 通义千问API端点（使用阿里云DashScope兼容模式）
      endpoint: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
      // 注意：实际项目中应从环境变量或配置文件获取API密钥
      apiKey: 'sk-f2885e8725e04ec690db459cea8bcc57',
      timeout: 30000, // 30秒超时
      maxRetries: 3 // 最大重试次数
    };
    
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
    
    // 缓存机制，提高性能
    this.cache = new Map();
  }

  /**
   * 智能解析资源/需求描述
   * @param {string} description - 资源/需求描述
   * @param {string} type - 类型：'resource' 或 'demand'
   * @returns {Promise<Object>} 解析结果
   */
  async parseDescription(description, type = 'resource') {
    console.log('========== 开始智能解析 ==========');
    console.log('输入描述:', description);
    console.log('资源类型:', type);
    
    // 检查缓存
    const cacheKey = `${type}:${description}`;
    if (this.cache.has(cacheKey)) {
      console.log('使用缓存结果');
      return this.cache.get(cacheKey);
    }

    try {
      console.log('准备调用通义千问API...');
      // 调用通义千问API
      const result = await this.callTongyiAPI(description, type);
      
      console.log('========== 通义千问API调用成功 ==========');
      console.log('解析结果:', JSON.stringify(result, null, 2));
      
      // 缓存结果
      this.cache.set(cacheKey, result);
      
      // 限制缓存大小
      if (this.cache.size > 100) {
        const firstKey = this.cache.keys().next().value;
        this.cache.delete(firstKey);
      }
      
      console.log('========== 智能解析完成 ==========');
      return result;
    } catch (error) {
      console.error('========== 通义千问API调用失败 ==========');
      console.error('错误信息:', error.message);
      console.error('错误堆栈:', error.stack);
      
      // 返回基础解析结果，确保功能不中断
      console.log('切换到降级解析方案...');
      const fallbackResult = this.fallbackParse(description, type);
      console.log('========== 降级解析完成 ==========');
      console.log('降级解析结果:', JSON.stringify(fallbackResult, null, 2));
      return fallbackResult;
    }
  }

  /**
   * 识别用户意图
   * @param {string} description - 用户输入描述
   * @returns {string} 识别结果：'find_resource' 或 'publish_demand'
   */
  identifyUserIntent(description) {
    console.log('开始识别用户意图:', description);
    
    // 寻找资源的关键词
    const findResourceKeywords = [
      '找', '寻找', '需要', '求', '求购', '求租', '想要', '寻找', '希望有', '哪里有',
      '有没有', '是否有', '需要一个', '需要一些', '需要帮助', '需要服务', '需要维修',
      '需要安装', '需要搬家', '需要租车', '需要人力', '需要技能', '需要物品',
      '我要', '我想', '我需要', '谁能', '谁有', '谁可以', '哪里可以', '哪里能'
    ];
    
    // 发布需求的关键词
    const publishDemandKeywords = [
      '发布', '提供', '出售', '出租', '转让', '闲置', '有', '可以提供', '可以帮忙',
      '专业', '服务', '技能', '工具', '车辆', '人力', '时间', '有空', '可', '能够',
      '愿意', '提供服务', '提供帮助', '提供技能', '提供物品', '提供车辆', '提供人力'
    ];
    
    // 计算关键词匹配数
    let findResourceCount = 0;
    let publishDemandCount = 0;
    
    for (const keyword of findResourceKeywords) {
      if (description.includes(keyword)) {
        findResourceCount++;
      }
    }
    
    for (const keyword of publishDemandKeywords) {
      if (description.includes(keyword)) {
        publishDemandCount++;
      }
    }
    
    console.log('寻找资源关键词匹配数:', findResourceCount);
    console.log('发布需求关键词匹配数:', publishDemandCount);
    
    // 根据匹配数确定意图
    if (findResourceCount > publishDemandCount) {
      console.log('识别结果: 寻找资源');
      return 'find_resource';
    } else if (publishDemandCount > findResourceCount) {
      console.log('识别结果: 发布需求');
      return 'publish_demand';
    } else {
      // 当匹配数相同时，根据上下文判断
      console.log('识别结果: 无法确定，默认返回寻找资源');
      return 'find_resource';
    }
  }

  /**
   * 智能解析搜索输入
   * @param {string} searchInput - 搜索输入
   * @returns {Promise<Object>} 解析结果，包含意图和结构化数据
   */
  async parseSearchInput(searchInput) {
    console.log('========== 开始搜索输入解析 ==========');
    console.log('搜索输入:', searchInput);
    
    // 检查缓存
    const cacheKey = `search:${searchInput}`;
    if (this.cache.has(cacheKey)) {
      console.log('使用缓存结果');
      return this.cache.get(cacheKey);
    }
    
    try {
      // 识别用户意图
      const intent = this.identifyUserIntent(searchInput);
      
      // 根据意图确定类型
      const type = intent === 'find_resource' ? 'demand' : 'resource';
      
      // 调用智能解析
      const parseResult = await this.parseDescription(searchInput, type);
      
      // 构建最终结果
      const result = {
        intent,
        type,
        parsedData: parseResult
      };
      
      // 缓存结果
      this.cache.set(cacheKey, result);
      
      // 限制缓存大小
      if (this.cache.size > 100) {
        const firstKey = this.cache.keys().next().value;
        this.cache.delete(firstKey);
      }
      
      console.log('========== 搜索输入解析完成 ==========');
      console.log('解析结果:', JSON.stringify(result, null, 2));
      return result;
    } catch (error) {
      console.error('========== 搜索输入解析失败 ==========');
      console.error('错误信息:', error.message);
      
      // 降级处理
      const intent = this.identifyUserIntent(searchInput);
      const type = intent === 'find_resource' ? 'demand' : 'resource';
      const fallbackResult = this.fallbackParse(searchInput, type);
      
      const result = {
        intent,
        type,
        parsedData: fallbackResult
      };
      
      console.log('降级解析结果:', JSON.stringify(result, null, 2));
      return result;
    }
  }

  /**
   * 调用通义千问API
   * @param {string} description - 资源/需求描述
   * @param {string} type - 类型：'resource' 或 'demand'
   * @returns {Promise<Object>} 解析结果
   */
  async callTongyiAPI(description, type) {
    let retries = 0;
    
    while (retries < this.apiConfig.maxRetries) {
      try {
        // 构建提示词
        const prompt = this.buildPrompt(description, type);
        
        // 准备API请求参数
        const requestData = {
          model: 'qwen-plus', // 通义千问模型
          messages: [
            {
              role: 'system',
              content: '你是一个智能资源/需求解析助手，专门用于解析用户输入的资源或需求描述，提取结构化信息。'
            },
            {
              role: 'user',
              content: prompt
            }
          ],
          temperature: 0.3, // 降低随机性，提高结构化输出的一致性
          max_tokens: 2000 // 足够的token数以确保完整输出
        };
        
        // 发送API请求
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), this.apiConfig.timeout);
        
        console.log('开始发送API请求');
        console.log('请求URL:', this.apiConfig.endpoint);
        console.log('请求数据:', requestData);
        
        try {
          const response = await fetch(this.apiConfig.endpoint, {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'Authorization': `Bearer ${this.apiConfig.apiKey}`
            },
            body: JSON.stringify(requestData),
            signal: controller.signal
          });
          
          clearTimeout(timeoutId);
          
          console.log('API响应状态:', response.status);
          
          if (!response.ok) {
            const errorText = await response.text();
            console.error('API请求失败:', errorText);
            
            // 处理常见的API错误
            if (response.status === 401) {
              throw new Error('API密钥无效或已过期');
            } else if (response.status === 403) {
              throw new Error('API调用权限不足');
            } else if (response.status === 404) {
              throw new Error('API端点不存在');
            } else if (response.status === 429) {
              throw new Error('API调用频率过高，请稍后重试');
            } else if (response.status >= 500) {
              throw new Error('服务器内部错误，请稍后重试');
            } else {
              throw new Error(`API请求失败: ${response.status} ${errorText}`);
            }
          }
          
          const data = await response.json();
          console.log('API响应数据:', data);
          
          // 处理API响应
          if (!data.choices || !data.choices[0] || !data.choices[0].message || !data.choices[0].message.content) {
            throw new Error('API响应格式错误');
          }
          
          // 解析JSON响应
          let result;
          try {
            result = JSON.parse(data.choices[0].message.content);
          } catch (parseError) {
            throw new Error('API返回的不是有效的JSON格式');
          }
          
          // 验证结果格式
          result = this.validateAndFormatResult(result, description, type);
          
          console.log('大模型解析成功，返回结果:', result);
          return result;
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
      } catch (error) {
        retries++;
        if (retries >= this.apiConfig.maxRetries) {
          console.error('API调用最终失败:', error);
          throw error;
        }
        
        // 指数退避重试，添加随机抖动以避免重试风暴
        const baseDelay = Math.pow(2, retries) * 1000;
        const jitter = Math.random() * 500; // 0-500ms的随机抖动
        const delay = baseDelay + jitter;
        
        console.log(`API调用失败，${Math.round(delay)}ms后重试... (${retries}/${this.apiConfig.maxRetries})`);
        console.log('错误信息:', error.message);
        
        await new Promise(resolve => setTimeout(resolve, delay));
      }
    }
  }



  /**
   * 增强描述内容
   * @param {string} description - 原始描述
   * @returns {string} 增强后的描述
   */
  enhanceDescription(description) {
    let enhanced = description.trim();
    
    // 确保描述以适当的标点符号结尾
    if (!/[。！？.!?]$/.test(enhanced)) {
      enhanced += '。';
    }
    
    // 添加一些标准化的表达
    if (!enhanced.includes('服务') && !enhanced.includes('资源') && !enhanced.includes('提供')) {
      enhanced = '提供' + enhanced;
    }
    
    // 优化描述结构
    if (enhanced.length > 50) {
      // 简单的句子分割和重组
      const sentences = enhanced.split(/[。！？.!?]/).filter(s => s.trim());
      if (sentences.length > 1) {
        enhanced = sentences.join('。') + '。';
      }
    }
    
    return enhanced;
  }

  /**
   * 构建提示词
   * @param {string} description - 资源/需求描述
   * @param {string} type - 类型：'resource' 或 'demand'
   * @returns {string} 提示词
   */
  buildPrompt(description, type) {
    // 识别行业模板
    const industry = this.getIndustryTemplates(description)[0];
    const industryInfo = this.industryTemplates[industry] || {};
    
    return `请智能解析以下资源/需求描述，提取结构化信息，并以JSON格式返回。\n\n` +
      `【描述】\n${description}\n\n` +
      `【类型】\n${type === 'resource' ? '资源' : '需求'}\n\n` +
      `【行业】\n${industry}\n\n` +
      `【需要提取的字段】\n` +
      `- name: 资源/需求名称（简洁明了）\n` +
      `- description: 详细描述（对原始信息进行专业优化，使其更清晰、结构化，突出关键信息）\n` +
      `- category: 分类信息，包含main（主分类：人、车、技能、物）和sub（子分类）\n` +
      `- ${type === 'resource' ? 'price' : 'budget'}: 价格或预算信息\n` +
      `- ${type === 'resource' ? 'serviceScope' : 'demandScope'}: 服务范围或需求范围\n` +
      `- timeRequirement: 时间要求\n` +
      `- location: 地点信息\n` +
      `- expirationDate: 有效截至日期（格式：YYYY-MM-DD）\n` +
      `- tags: 相关标签数组\n` +
      `- industry: 所属行业\n\n` +
      `【注意事项】\n` +
      `1. 严格按照JSON格式返回，不要包含任何额外文本\n` +
      `2. 确保所有字段都有合理的值，对于无法提取的字段返回null\n` +
      `3. 分类信息中的main字段只能是：人、车、技能、物中的一个\n` +
      `4. 有效截至日期如果没有明确指定，默认设为30天后\n` +
      `5. 标签应包含行业标签、服务类型标签（如上门、远程等）、价格标签（如免费、优惠等）和时间标签（如紧急、长期等）\n` +
      `6. 服务范围应包含具体的服务内容和覆盖区域\n` +
      `7. 时间要求应包含具体的服务时间或时间范围\n` +
      `8. 地点信息应包含具体的服务地点或覆盖区域\n` +
      `9. description字段必须对原始描述进行专业优化，使其更清晰、结构化，突出关键信息，而不是简单复制原始内容\n` +
      `10. description字段应包括资源的主要特点、优势、服务内容等，使其更具吸引力\n\n` +
      `【示例输出】\n` +
      `{\n` +
      `  "name": "专业家政保洁服务",\n` +
      `  "description": "提供专业家政保洁服务，包括日常保洁、深度清洁等，价格合理，服务周到。",\n` +
      `  "category": {\n` +
      `    "main": "人",\n` +
      `    "sub": "家政"\n` +
      `  },\n` +
      `  "price": "50元/小时",\n` +
      `  "serviceScope": "日常保洁、深度清洁、开荒保洁",\n` +
      `  "timeRequirement": "周一至周日 8:00-20:00",\n` +
      `  "location": "北京市朝阳区",\n` +
      `  "expirationDate": "2026-02-28",\n` +
      `  "tags": ["家政", "上门服务", "保洁"],\n` +
      `  "industry": "家政"
` +
      `}\n` +
      `\n` +
      `【另一个示例】\n` +
      `{\n` +
      `  "name": "SUV汽车出租",\n` +
      `  "description": "提供闲置SUV汽车出租服务，车辆状况良好，手续齐全，已购买保险，安全可靠。每日租金300元，支持日租和月租多种租赁方式，满足不同客户需求。车辆位于北京市朝阳区，交通便利，取车方便。",\n` +
      `  "category": {\n` +
      `    "main": "车",\n` +
      `    "sub": "汽车租赁"\n` +
      `  },\n` +
      `  "price": "300元/天",\n` +
      `  "serviceScope": "SUV汽车租赁服务，含车辆使用权，手续齐全，有保险",\n` +
      `  "timeRequirement": "可日租也可月租",\n` +
      `  "location": "北京市朝阳区",\n` +
      `  "expirationDate": "2026-02-28",\n` +
      `  "tags": ["汽车租赁", "SUV", "日租", "月租", "北京朝阳"],\n` +
      `  "industry": "通用"\n` +
      `}`;
  }

  /**
   * 验证和格式化解析结果
   * @param {Object} result - 解析结果
   * @param {string} description - 原始描述
   * @param {string} type - 类型
   * @returns {Object} 验证和格式化后的结果
   */
  validateAndFormatResult(result, description, type) {
    // 确保所有必要字段都存在
    const requiredFields = [
      'name', 'description', 'category', 
      type === 'resource' ? 'price' : 'budget',
      type === 'resource' ? 'serviceScope' : 'demandScope',
      'timeRequirement', 'location', 'expirationDate', 'tags', 'industry'
    ];
    
    for (const field of requiredFields) {
      if (result[field] === undefined) {
        result[field] = null;
      }
    }
    
    // 确保分类信息格式正确
    if (!result.category || typeof result.category !== 'object') {
      result.category = this.extractCategory(description);
    } else if (!result.category.main) {
      result.category.main = '其他';
    } else if (!['人', '车', '技能', '物'].includes(result.category.main)) {
      // 映射到正确的主分类
      const categoryMap = {
        '人力资源': '人',
        '车辆': '车',
        '技术': '技能',
        '物品': '物'
      };
      result.category.main = categoryMap[result.category.main] || '其他';
    }
    
    // 确保标签是数组
    if (!Array.isArray(result.tags)) {
      result.tags = this.generateTags(description);
    }
    
    // 确保有效截至日期格式正确
    if (!result.expirationDate) {
      const defaultExpiration = new Date();
      defaultExpiration.setDate(defaultExpiration.getDate() + 30);
      result.expirationDate = defaultExpiration.toISOString().split('T')[0];
    }
    
    // 确保行业信息存在
    if (!result.industry) {
      result.industry = this.getIndustryTemplates(description)[0];
    }
    
    // 确保描述存在
    if (!result.description) {
      result.description = description;
    }
    
    // 确保名称存在
    if (!result.name) {
      result.name = this.extractName(description);
    }
    
    return result;
  }

  /**
   * 获取行业特定解析模板
   * @param {string} description - 资源/需求描述
   * @returns {Array} 匹配的行业模板
   */
  getIndustryTemplates(description) {
    const matchedTemplates = [];
    
    for (const [industry, template] of Object.entries(this.industryTemplates)) {
      if (template.keywords.some(keyword => description.includes(keyword))) {
        matchedTemplates.push(industry);
      }
    }
    
    return matchedTemplates.length > 0 ? matchedTemplates : ['通用'];
  }

  /**
   * 提取资源/需求名称
   * @param {string} description - 资源/需求描述
   * @returns {string} 名称
   */
  extractName(description) {
    // 简单提取前20个字符作为名称
    return description.substring(0, 20) + (description.length > 20 ? '...' : '');
  }

  /**
   * 提取分类
   * @param {string} description - 资源/需求描述
   * @returns {Object} 分类信息
   */
  extractCategory(description) {
    // 简单的分类映射
    const categoryMap = {
      '人': ['兼职', '服务', '协作', '人力', '家政', '保洁', '保姆', '月嫂'],
      '车': ['搬家', '货运', '运输', '租车', '快递', '物流', '配送'],
      '技能': ['编程', '设计', '维修', '技术', 'IT服务', '咨询', '培训'],
      '物': ['出租', '转让', '出售', '闲置', '设备', '工具', '家具']
    };

    for (const [mainCategory, keywords] of Object.entries(categoryMap)) {
      if (keywords.some(keyword => description.includes(keyword))) {
        return {
          main: mainCategory,
          sub: keywords.find(keyword => description.includes(keyword)) || '其他'
        };
      }
    }

    return {
      main: '其他',
      sub: '其他'
    };
  }

  /**
   * 提取价格
   * @param {string} description - 资源/需求描述
   * @returns {string|null} 价格
   */
  extractPrice(description) {
    const priceRegex = /(\d+(?:\.\d+)?)\s*(元|¥|价格|收费)/i;
    const match = description.match(priceRegex);
    return match ? match[1] + match[2] : null;
  }

  /**
   * 提取服务范围
   * @param {string} description - 资源/需求描述
   * @returns {string|null} 服务范围
   */
  extractServiceScope(description) {
    // 简单提取服务内容
    if (description.includes('服务')) {
      const startIndex = description.indexOf('服务');
      const endIndex = description.indexOf('，', startIndex);
      if (endIndex > startIndex) {
        return description.substring(startIndex, endIndex);
      }
    }
    return null;
  }

  /**
   * 提取时间要求
   * @param {string} description - 资源/需求描述
   * @returns {string|null} 时间要求
   */
  extractTimeRequirement(description) {
    const timeRegex = /(\d+[天小时分钟])|([0-9]{1,2}:[0-9]{2})|(上午|下午|晚上)/i;
    const match = description.match(timeRegex);
    return match ? match[0] : null;
  }

  /**
   * 提取地点
   * @param {string} description - 资源/需求描述
   * @returns {string|null} 地点
   */
  extractLocation(description) {
    // 简单提取地点
    const locationKeywords = ['在', '位于', '地址', '地方'];
    for (const keyword of locationKeywords) {
      if (description.includes(keyword)) {
        const startIndex = description.indexOf(keyword) + keyword.length;
        const endIndex = description.indexOf('，', startIndex);
        if (endIndex > startIndex) {
          return description.substring(startIndex, endIndex).trim();
        }
      }
    }
    return null;
  }

  /**
   * 提取有效截至日期
   * @param {string} description - 资源/需求描述
   * @returns {string|null} 有效截至日期
   */
  extractExpirationDate(description) {
    // 匹配日期格式：YYYY-MM-DD, YYYY/MM/DD, MM-DD, 今天, 明天, 本周, 本月等
    const dateRegex = /(\d{4}[-/]\d{1,2}[-/]\d{1,2})|(\d{1,2}[-/]\d{1,2})|(今天|明天|后天|本周|本月|下月|明年)/i;
    const match = description.match(dateRegex);
    
    if (match) {
      const dateStr = match[0];
      // 简单处理日期格式
      if (dateStr.includes('今天')) {
        return new Date().toISOString().split('T')[0];
      } else if (dateStr.includes('明天')) {
        const tomorrow = new Date();
        tomorrow.setDate(tomorrow.getDate() + 1);
        return tomorrow.toISOString().split('T')[0];
      } else if (dateStr.includes('本周')) {
        const nextWeek = new Date();
        nextWeek.setDate(nextWeek.getDate() + 7);
        return nextWeek.toISOString().split('T')[0];
      } else if (dateStr.includes('本月')) {
        const nextMonth = new Date();
        nextMonth.setMonth(nextMonth.getMonth() + 1);
        return nextMonth.toISOString().split('T')[0];
      }
      return dateStr;
    }
    
    // 默认有效期为30天
    const defaultExpiration = new Date();
    defaultExpiration.setDate(defaultExpiration.getDate() + 30);
    return defaultExpiration.toISOString().split('T')[0];
  }

  /**
   * 生成标签
   * @param {string} description - 资源/需求描述
   * @returns {Array} 标签列表
   */
  generateTags(description) {
    const tags = [];
    
    // 行业标签
    const industry = this.getIndustryTemplates(description)[0];
    if (industry && industry !== '通用') {
      tags.push(industry);
    }
    
    // 服务类型标签
    const serviceTypes = ['上门', '远程', '在线', '到店'];
    for (const type of serviceTypes) {
      if (description.includes(type)) {
        tags.push(type);
      }
    }
    
    // 价格标签
    if (description.includes('免费')) {
      tags.push('免费');
    } else if (description.includes('优惠')) {
      tags.push('优惠');
    }
    
    // 时间标签
    if (description.includes('紧急')) {
      tags.push('紧急');
    } else if (description.includes('长期')) {
      tags.push('长期');
    }
    
    return tags;
  }

  /**
   * 增强的降级解析方案
   * @param {string} description - 资源/需求描述
   * @param {string} type - 类型：'resource' 或 'demand'
   * @returns {Object} 解析结果
   */
  fallbackParse(description, type = 'resource') {
    console.warn('使用降级解析方案');
    
    // 增强的降级解析逻辑
    const baseResult = {
      name: this.extractName(description),
      description: this.enhanceDescription(description),
      category: this.extractCategory(description),
      timeRequirement: this.extractTimeRequirement(description),
      location: this.extractLocation(description),
      expirationDate: this.extractExpirationDate(description),
      tags: this.generateTags(description),
      industry: this.getIndustryTemplates(description)[0]
    };

    // 根据类型添加价格或预算
    if (type === 'resource') {
      baseResult.price = this.extractPrice(description);
      baseResult.serviceScope = this.extractServiceScope(description);
    } else {
      baseResult.budget = this.extractPrice(description);
      baseResult.demandScope = this.extractServiceScope(description);
    }

    console.log('降级解析结果:', baseResult);
    return baseResult;
  }

  /**
   * 清理缓存
   */
  clearCache() {
    this.cache.clear();
  }

  /**
   * 获取缓存大小
   * @returns {number} 缓存大小
   */
  getCacheSize() {
    return this.cache.size;
  }
}

// 导出单例
const smartParseService = new SmartParseService();

// 暴露为全局变量（浏览器环境）
if (typeof window !== 'undefined') {
  window.smartParseService = smartParseService;
}

// 导出为模块（Node.js环境）
if (typeof module !== 'undefined' && module.exports) {
  module.exports = SmartParseService;
  module.exports.smartParseService = smartParseService;
}