package com.s2s.server.chat.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.s2s.server.chat.entity.ConversationEntity;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

/**
 * 会话 Mapper（映射表 {@code conversation}）。
 *
 * <p>{@link BaseMapper} 承载单行读写；{@link #selectByIdForUpdate(Long)} 是发送消息时
 * 「串行取号」的行锁入口（KTD3）；{@link #selectPageForUser} / {@link #countForUser}
 * 承载消息 Tab 的列表查询（U4，联表取对方与帖子摘要）。</p>
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

    /**
     * 分页查询某用户的会话列表（按最后消息时间倒序，含对方与帖子摘要）。
     *
     * <p>隐藏窗口由 {@code visibleSince} 作为查询下界（KTD8）：不写状态、不做定时任务，
     * 新的往来写入后自然重新可见。</p>
     *
     * @param userId       当前用户 ID
     * @param visibleSince 隐藏窗口下界（{@code now - ChatLimits.CONVERSATION_HIDE_AFTER_DAYS}）
     * @param offset       偏移量
     * @param limit        每页条数
     * @return {@link List} 行映射（列名见 {@code ConversationMapper.xml}）
     */
    List<Map<String, Object>> selectPageForUser(@Param("userId") Long userId,
            @Param("visibleSince") LocalDateTime visibleSince,
            @Param("offset") int offset,
            @Param("limit") int limit);

    /**
     * 统计某用户可见会话总数（与 {@link #selectPageForUser} 同一筛选口径）。
     *
     * @param userId       当前用户 ID
     * @param visibleSince 隐藏窗口下界
     * @return long 会话总数
     */
    long countForUser(@Param("userId") Long userId,
            @Param("visibleSince") LocalDateTime visibleSince);
}
