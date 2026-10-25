package com.s2s.server.task;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
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
 *
 * <p><b>一次性运维进程必须关掉调度</b>：小区回填（{@code CommunityBackfillRunner}）等
 * 运维任务会以「同一镜像再起一个短命进程」的方式执行，它会完整装配 Spring 上下文。
 * 若不禁用调度，这 11 个任务就会与常驻实例并发跑，直接违反上面的单实例前提。
 * 故加 {@code s2s.scheduling.enabled} 开关（缺省 true，不影响常驻实例），
 * 运维进程显式传 {@code --s2s.scheduling.enabled=false}。</p>
 */
@Configuration
@EnableScheduling
@ConditionalOnProperty(name = "s2s.scheduling.enabled", havingValue = "true",
        matchIfMissing = true)
public class TaskSchedulingConfig {
}
