package com.s2s.server.task;

import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * 定时任务调度开关（[129] P4；详设 §6 + 架构 §8「R12：应用进程内 Spring 调度，不引入独立
 * 调度中间件」）。
 *
 * <p><b>为什么单独一个配置类而不把 {@code @EnableScheduling} 加在启动类</b>：启动类是
 * 「包结构 + 装配根」，其注解每多一条都会让后人误以为它是某功能的开关；调度是 task 包
 * 的存在前提，放在此处与各任务类同包，读代码时「为什么这些方法会自动跑」的答案就在隔壁。</p>
 *
 * <p><b>单实例前提（必须随代码传递的口径）</b>：详设 §6 明写「单实例部署 + Spring
 * {@code @Scheduled}，<b>无需分布式锁</b>；若未来扩为多实例，11 项任务必须同时引入分布式锁」。
 * 当前部署形态为单实例（架构 §4）。<b>多实例部署前，本包全部任务必须先加分布式锁</b>——
 * 否则到期下架、月表 DROP、注销清理会在多个实例上并发重复执行（DROP 与 DELETE 重复执行
 * 尚可容忍，但「按月表名解析并删除」这类操作在并发下会出现彼此删同一张表与元数据竞争）。</p>
 */
@Configuration
@EnableScheduling
public class TaskSchedulingConfig {
}
