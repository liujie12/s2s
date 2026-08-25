/**
 * 防抖工具类
 * 用于优化用户输入和交互性能，防止频繁触发匹配请求
 */
class DebounceUtil {
    /**
     * 构造函数
     * @param {number} delay 延迟时间（毫秒）
     */
    constructor(delay = 300) {
        this.delay = delay;
        this.timers = new Map();
    }

    /**
     * 防抖函数
     * @param {string} key 唯一标识
     * @param {Function} callback 回调函数
     * @param {number} [customDelay] 自定义延迟时间
     */
    debounce(key, callback, customDelay) {
        // 清除之前的定时器
        if (this.timers.has(key)) {
            clearTimeout(this.timers.get(key));
        }
        
        // 设置新的定时器
        const delay = customDelay || this.delay;
        const timer = setTimeout(() => {
            callback();
            this.timers.delete(key);
        }, delay);
        
        this.timers.set(key, timer);
    }

    /**
     * 立即执行并防抖
     * @param {string} key 唯一标识
     * @param {Function} callback 回调函数
     * @param {number} [customDelay] 自定义延迟时间
     */
    immediate(key, callback, customDelay) {
        // 清除之前的定时器
        if (this.timers.has(key)) {
            clearTimeout(this.timers.get(key));
        }
        
        // 立即执行
        callback();
        
        // 设置新的定时器
        const delay = customDelay || this.delay;
        const timer = setTimeout(() => {
            this.timers.delete(key);
        }, delay);
        
        this.timers.set(key, timer);
    }

    /**
     * 清除指定的防抖定时器
     * @param {string} key 唯一标识
     */
    clear(key) {
        if (this.timers.has(key)) {
            clearTimeout(this.timers.get(key));
            this.timers.delete(key);
        }
    }

    /**
     * 清除所有防抖定时器
     */
    clearAll() {
        for (const timer of this.timers.values()) {
            clearTimeout(timer);
        }
        this.timers.clear();
    }

    /**
     * 获取当前活跃的定时器数量
     * @returns {number} 活跃定时器数量
     */
    getActiveTimerCount() {
        return this.timers.size;
    }

    /**
     * 检查是否存在指定的防抖定时器
     * @param {string} key 唯一标识
     * @returns {boolean} 是否存在
     */
    has(key) {
        return this.timers.has(key);
    }
}

// 创建默认实例
const debounceUtil = new DebounceUtil();

/**
 * 便捷的防抖函数
 * @param {Function} func 要执行的函数
 * @param {number} delay 延迟时间
 * @returns {Function} 防抖处理后的函数
 */
function debounce(func, delay = 300) {
    let timeoutId;
    
    return function(...args) {
        clearTimeout(timeoutId);
        timeoutId = setTimeout(() => {
            func.apply(this, args);
        }, delay);
    };
}

/**
 * 便捷的节流函数
 * @param {Function} func 要执行的函数
 * @param {number} limit 时间限制
 * @returns {Function} 节流处理后的函数
 */
function throttle(func, limit = 300) {
    let inThrottle;
    
    return function(...args) {
        if (!inThrottle) {
            func.apply(this, args);
            inThrottle = true;
            setTimeout(() => {
                inThrottle = false;
            }, limit);
        }
    };
}

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        DebounceUtil,
        debounceUtil,
        debounce,
        throttle
    };
} else if (typeof window !== 'undefined') {
    window.DebounceUtil = DebounceUtil;
    window.debounceUtil = debounceUtil;
    window.debounce = debounce;
    window.throttle = throttle;
}