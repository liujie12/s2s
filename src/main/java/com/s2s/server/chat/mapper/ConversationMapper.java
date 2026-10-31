package com.s2s.server.chat.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.chat.entity.ConversationEntity;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 会话 Mapper（映射表 {@code conversation}）。
 *
 * <p>{@link BaseMapper} 承载单行读写；{@link #selectByIdForUpdate(Long)} 是发送消息时
 * 「串行取号」的行锁入口（KTD3）——并发发送靠它把同一会话的 {@code last_seq} 自增
 * 排成队，避免两条消息拿到同一个序号。</p>
 */
@Mapper
public interface ConversationMapper extends BaseMapper<ConversationEntity> {

    /**
     * 按主键加行锁读取会话（{@code SELECT ... FOR UPDATE}）。
     *
     * <p>必须在本类的事务方法内调用：锁随事务提交/回滚释放。取到后按
     * {@code last_seq + 1} 分配序号并写消息，同一会话的发送因此串行化。</p>
     *
     * @param id 会话 ID
     * @return {@link ConversationEntity} 加锁读到的会话；不存在时 {@code null}
     */
    ConversationEntity selectByIdForUpdate(@Param("id") Long id);
}
