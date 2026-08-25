/**
 * 个性化匹配服务模块
 * 实现基于用户历史行为和偏好的个性化匹配
 */
class PersonalizationService {
  /**
   * 构造函数
   * @param {Object} options 配置选项
   */
  constructor(options = {}) {
    // 行为数据存储
    this.behaviorData = new Map();
    // 用户画像存储
    this.userProfiles = new Map();
    // 配置选项
    this.options = {
      behaviorLimit: options.behaviorLimit || 100, // 每个用户最多存储的行为记录数
      profileUpdateInterval: options.profileUpdateInterval || 5000, // 用户画像更新间隔（毫秒）
      ...options
    };
  }

  /**
   * 记录用户行为
   * @param {string} userId - 用户ID
   * @param {Object} behavior - 行为数据
   */
  recordUserBehavior(userId, behavior) {
    console.log('记录用户行为:', userId, behavior);
    
    if (!userId || !behavior) return;
    
    // 确保用户行为数据结构存在
    if (!this.behaviorData.has(userId)) {
      this.behaviorData.set(userId, []);
    }
    
    // 添加行为记录
    const behaviors = this.behaviorData.get(userId);
    behaviors.push({
      ...behavior,
      timestamp: Date.now(),
      id: `behavior_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`
    });
    
    // 限制行为记录数量
    if (behaviors.length > this.options.behaviorLimit) {
      behaviors.shift(); // 删除最早的记录
    }
    
    // 更新用户画像
    this.updateUserProfile(userId);
  }

  /**
   * 获取用户行为数据
   * @param {string} userId - 用户ID
   * @returns {Array} 行为数据数组
   */
  getUserBehaviors(userId) {
    return this.behaviorData.get(userId) || [];
  }

  /**
   * 更新用户画像
   * @param {string} userId - 用户ID
   */
  updateUserProfile(userId) {
    console.log('更新用户画像:', userId);
    
    const behaviors = this.getUserBehaviors(userId);
    if (behaviors.length === 0) {
      // 创建默认用户画像
      this.userProfiles.set(userId, this.createDefaultProfile());
      return;
    }
    
    // 分析行为数据，构建用户画像
    const profile = this.analyzeBehaviors(behaviors);
    this.userProfiles.set(userId, profile);
    
    console.log('用户画像更新完成:', profile);
  }

  /**
   * 创建默认用户画像
   * @returns {Object} 默认用户画像
   */
  createDefaultProfile() {
    return {
      preferences: {
        categories: {},
        priceRanges: {},
        timeSlots: {},
        locations: {}
      },
      behaviorPatterns: {
        searchFrequency: 'low',
        responseTime: 'medium',
        interactionLevel: 'low'
      },
      lastUpdated: Date.now()
    };
  }

  /**
   * 分析用户行为数据
   * @param {Array} behaviors - 行为数据数组
   * @returns {Object} 用户画像
   */
  analyzeBehaviors(behaviors) {
    const profile = this.createDefaultProfile();
    
    // 分类偏好分析
    const categoryCounts = {};
    // 价格偏好分析
    const priceRanges = {
      low: 0, // 0-50元
      medium: 0, // 51-200元
      high: 0 // 200元以上
    };
    // 时间偏好分析
    const timeSlots = {
      morning: 0, // 6:00-12:00
      afternoon: 0, // 12:00-18:00
      evening: 0, // 18:00-24:00
      night: 0 // 0:00-6:00
    };
    // 位置偏好分析
    const locationCounts = {};
    
    // 分析行为数据
    behaviors.forEach(behavior => {
      // 搜索行为分析
      if (behavior.type === 'search') {
        // 分析搜索关键词
        if (behavior.keyword) {
          // 提取可能的分类信息
          const categories = this.extractCategoriesFromKeyword(behavior.keyword);
          categories.forEach(category => {
            categoryCounts[category] = (categoryCounts[category] || 0) + 1;
          });
        }
      }
      
      // 查看行为分析
      if (behavior.type === 'view' && behavior.resource) {
        const resource = behavior.resource;
        
        // 分析资源分类
        if (resource.category) {
          categoryCounts[resource.category] = (categoryCounts[resource.category] || 0) + 1;
        }
        
        // 分析价格范围
        if (resource.price) {
          const price = this.parsePrice(resource.price);
          if (price <= 50) {
            priceRanges.low++;
          } else if (price <= 200) {
            priceRanges.medium++;
          } else {
            priceRanges.high++;
          }
        }
        
        // 分析位置
        if (resource.location) {
          locationCounts[resource.location] = (locationCounts[resource.location] || 0) + 1;
        }
      }
      
      // 时间分析
      const hour = new Date(behavior.timestamp).getHours();
      if (hour >= 6 && hour < 12) {
        timeSlots.morning++;
      } else if (hour >= 12 && hour < 18) {
        timeSlots.afternoon++;
      } else if (hour >= 18 && hour < 24) {
        timeSlots.evening++;
      } else {
        timeSlots.night++;
      }
    });
    
    // 更新分类偏好
    profile.preferences.categories = categoryCounts;
    // 更新价格偏好
    profile.preferences.priceRanges = priceRanges;
    // 更新时间偏好
    profile.preferences.timeSlots = timeSlots;
    // 更新位置偏好
    profile.preferences.locations = locationCounts;
    
    // 分析行为模式
    const searchBehaviors = behaviors.filter(b => b.type === 'search');
    const viewBehaviors = behaviors.filter(b => b.type === 'view');
    
    // 搜索频率
    if (searchBehaviors.length > 20) {
      profile.behaviorPatterns.searchFrequency = 'high';
    } else if (searchBehaviors.length > 5) {
      profile.behaviorPatterns.searchFrequency = 'medium';
    }
    
    // 互动水平
    if (viewBehaviors.length > 30) {
      profile.behaviorPatterns.interactionLevel = 'high';
    } else if (viewBehaviors.length > 10) {
      profile.behaviorPatterns.interactionLevel = 'medium';
    }
    
    profile.lastUpdated = Date.now();
    return profile;
  }

  /**
   * 从关键词中提取分类信息
   * @param {string} keyword - 搜索关键词
   * @returns {Array} 分类数组
   */
  extractCategoriesFromKeyword(keyword) {
    const categories = [];
    const categoryKeywords = {
      '人': ['兼职', '服务', '协作', '人力', '家政', '保洁', '保姆', '月嫂'],
      '车': ['搬家', '货运', '运输', '租车', '快递', '物流', '配送'],
      '技能': ['编程', '设计', '维修', '技术', 'IT服务', '咨询', '培训'],
      '物': ['出租', '转让', '出售', '闲置', '设备', '工具', '家具']
    };
    
    for (const [category, keywords] of Object.entries(categoryKeywords)) {
      if (keywords.some(key => keyword.includes(key))) {
        categories.push(category);
      }
    }
    
    return categories;
  }

  /**
   * 解析价格字符串
   * @param {string} priceStr - 价格字符串
   * @returns {number} 价格数值
   */
  parsePrice(priceStr) {
    if (!priceStr) return 0;
    const match = priceStr.match(/\d+(\.\d+)?/);
    return match ? parseFloat(match[0]) : 0;
  }

  /**
   * 获取用户画像
   * @param {string} userId - 用户ID
   * @returns {Object} 用户画像
   */
  getUserProfile(userId) {
    if (!userId) return this.createDefaultProfile();
    
    if (!this.userProfiles.has(userId)) {
      this.updateUserProfile(userId);
    }
    
    return this.userProfiles.get(userId);
  }

  /**
   * 计算资源与用户偏好的匹配度
   * @param {string} userId - 用户ID
   * @param {Object} resource - 资源对象
   * @returns {number} 偏好匹配度（0-1）
   */
  calculatePreferenceMatch(userId, resource) {
    const profile = this.getUserProfile(userId);
    if (!profile) return 0.5;
    
    let totalScore = 0;
    let factorCount = 0;
    
    // 分类偏好匹配
    if (resource.category && profile.preferences.categories) {
      const categoryScore = this.calculateCategoryPreferenceMatch(resource.category, profile.preferences.categories);
      totalScore += categoryScore;
      factorCount++;
    }
    
    // 价格偏好匹配
    if (resource.price && profile.preferences.priceRanges) {
      const priceScore = this.calculatePricePreferenceMatch(resource.price, profile.preferences.priceRanges);
      totalScore += priceScore;
      factorCount++;
    }
    
    // 位置偏好匹配
    if (resource.location && profile.preferences.locations) {
      const locationScore = this.calculateLocationPreferenceMatch(resource.location, profile.preferences.locations);
      totalScore += locationScore;
      factorCount++;
    }
    
    // 计算平均匹配度
    return factorCount > 0 ? totalScore / factorCount : 0.5;
  }

  /**
   * 计算分类偏好匹配度
   * @param {string} resourceCategory - 资源分类
   * @param {Object} categoryPreferences - 分类偏好
   * @returns {number} 分类匹配度（0-1）
   */
  calculateCategoryPreferenceMatch(resourceCategory, categoryPreferences) {
    const totalCategoryCount = Object.values(categoryPreferences).reduce((sum, count) => sum + count, 0);
    if (totalCategoryCount === 0) return 0.5;
    
    // 检查直接匹配
    if (categoryPreferences[resourceCategory]) {
      return categoryPreferences[resourceCategory] / totalCategoryCount;
    }
    
    // 检查子分类匹配
    for (const [category, count] of Object.entries(categoryPreferences)) {
      if (resourceCategory.includes(category) || category.includes(resourceCategory)) {
        return count / totalCategoryCount * 0.8;
      }
    }
    
    return 0.3;
  }

  /**
   * 计算价格偏好匹配度
   * @param {string} resourcePrice - 资源价格
   * @param {Object} pricePreferences - 价格偏好
   * @returns {number} 价格匹配度（0-1）
   */
  calculatePricePreferenceMatch(resourcePrice, pricePreferences) {
    const price = this.parsePrice(resourcePrice);
    const totalPriceCount = Object.values(pricePreferences).reduce((sum, count) => sum + count, 0);
    if (totalPriceCount === 0) return 0.5;
    
    let preferredRange;
    if (price <= 50) {
      preferredRange = 'low';
    } else if (price <= 200) {
      preferredRange = 'medium';
    } else {
      preferredRange = 'high';
    }
    
    return (pricePreferences[preferredRange] || 0) / totalPriceCount || 0.3;
  }

  /**
   * 计算位置偏好匹配度
   * @param {string} resourceLocation - 资源位置
   * @param {Object} locationPreferences - 位置偏好
   * @returns {number} 位置匹配度（0-1）
   */
  calculateLocationPreferenceMatch(resourceLocation, locationPreferences) {
    const totalLocationCount = Object.values(locationPreferences).reduce((sum, count) => sum + count, 0);
    if (totalLocationCount === 0) return 0.5;
    
    // 检查直接匹配
    if (locationPreferences[resourceLocation]) {
      return locationPreferences[resourceLocation] / totalLocationCount;
    }
    
    // 检查部分匹配
    for (const [location, count] of Object.entries(locationPreferences)) {
      if (resourceLocation.includes(location) || location.includes(resourceLocation)) {
        return count / totalLocationCount * 0.8;
      }
    }
    
    return 0.3;
  }

  /**
   * 个性化排序资源列表
   * @param {string} userId - 用户ID
   * @param {Array} resources - 资源列表
   * @returns {Array} 排序后的资源列表
   */
  personalizeResourceList(userId, resources) {
    console.log('开始个性化排序资源列表:', userId, resources.length);
    
    // 计算每个资源的偏好匹配度
    const resourcesWithScores = resources.map(resource => {
      const preferenceScore = this.calculatePreferenceMatch(userId, resource);
      return {
        ...resource,
        preferenceScore,
        // 综合匹配度 = 原匹配度 * 0.7 + 偏好匹配度 * 0.3
        finalMatchScore: (resource.matchScore || 0.5) * 0.7 + preferenceScore * 0.3
      };
    });
    
    // 按综合匹配度排序
    resourcesWithScores.sort((a, b) => b.finalMatchScore - a.finalMatchScore);
    
    console.log('个性化排序完成');
    return resourcesWithScores;
  }

  /**
   * 获取用户偏好设置
   * @param {string} userId - 用户ID
   * @returns {Object} 用户偏好设置
   */
  getUserPreferences(userId) {
    const profile = this.getUserProfile(userId);
    if (!profile) return {};
    
    // 提取主要偏好
    const preferences = {
      favoriteCategories: this.getTopPreferences(profile.preferences.categories, 3),
      preferredPriceRange: this.getPreferredPriceRange(profile.preferences.priceRanges),
      frequentLocations: this.getTopPreferences(profile.preferences.locations, 3),
      behaviorPatterns: profile.behaviorPatterns
    };
    
    return preferences;
  }

  /**
   * 获取 top N 偏好
   * @param {Object} preferences - 偏好对象
   * @param {number} count - 数量
   * @returns {Array} top N 偏好数组
   */
  getTopPreferences(preferences, count = 3) {
    if (!preferences) return [];
    
    return Object.entries(preferences)
      .sort((a, b) => b[1] - a[1])
      .slice(0, count)
      .map(([key]) => key);
  }

  /**
   * 获取首选价格范围
   * @param {Object} priceRanges - 价格范围偏好
   * @returns {string} 首选价格范围
   */
  getPreferredPriceRange(priceRanges) {
    if (!priceRanges) return 'medium';
    
    const ranges = Object.entries(priceRanges);
    if (ranges.length === 0) return 'medium';
    
    ranges.sort((a, b) => b[1] - a[1]);
    return ranges[0][0];
  }

  /**
   * 清除用户数据
   * @param {string} userId - 用户ID
   */
  clearUserData(userId) {
    if (userId) {
      this.behaviorData.delete(userId);
      this.userProfiles.delete(userId);
    }
  }

  /**
   * 获取服务状态
   * @returns {Object} 服务状态
   */
  getStatus() {
    return {
      userCount: this.behaviorData.size,
      totalBehaviorRecords: Array.from(this.behaviorData.values()).reduce((sum, behaviors) => sum + behaviors.length, 0),
      profileCount: this.userProfiles.size
    };
  }
}

// 导出服务实例
const personalizationService = new PersonalizationService();

// 暴露为全局变量
if (typeof window !== 'undefined') {
  window.PersonalizationService = PersonalizationService;
  window.personalizationService = personalizationService;
}

// 导出为模块（Node.js环境）
if (typeof module !== 'undefined' && module.exports) {
  module.exports = PersonalizationService;
  module.exports.personalizationService = personalizationService;
}
