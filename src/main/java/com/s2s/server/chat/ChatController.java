package com.s2s.server.chat;

import com.s2s.server.chat.dto.ConversationCreateRequest;
import com.s2s.server.chat.dto.ConversationCreateResponse;
import com.s2s.server.chat.dto.MessageSendRequest;
import com.s2s.server.chat.dto.MessageSendResponse;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.idempotency.Idempotent;
import com.s2s.server.common.web.AuthContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * 会话域控制器（V30 / 计划 U2；详设 §5.5 的同构写法）。
 *
 * <p>职责：承载会话相关 HTTP 入口。本版有「开启或复用会话」与「发送文本消息」两个
 * 写接口；列表与已读（U4）、申请审批（U6）、举报（U7）后续并入本控制器
 * 或各自的 {@code ChatQueryController}，路由前缀统一 {@code /conversations}。</p>
 *
 * <p>返回 DTO 由 {@code ResponseBodyWrapper} 统一套壳，本类不写 {@code ApiResponse}。</p>
 */
@RestController
public class ChatController {

    private final ChatService chatService;
    private final ChatMessageService chatMessageService;

    /**
     * 构造会话控制器。
     *
     * @param chatService        会话主链服务
     * @param chatMessageService 消息发送服务
     */
    public ChatController(ChatService chatService, ChatMessageService chatMessageService) {
        this.chatService = chatService;
        this.chatMessageService = chatMessageService;
    }

    /**
     * 开启或复用会话（{@code POST /conversations}）。
     *
     * <p>必带 {@code Idempotency-Key}：双击或网络重试沿用同一键时返回首次结果，
     * 不会产生第二条会话、也不会重复消耗每日额度。</p>
     *
     * @param request     开会话入参（帖子 ID）
     * @param httpRequest 当前请求（取登录态）
     * @return {@link ConversationCreateResponse}（会话 ID + 是否新建）
     */
    @PostMapping("/conversations")
    @Idempotent
    public ConversationCreateResponse openConversation(
            @Valid @RequestBody ConversationCreateRequest request,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return chatService.openConversation(userId, request);
    }

    /**
     * 在会话内发送文本消息（{@code POST /conversations/{conversation_id}/messages}）。
     *
     * <p>必带 {@code Idempotency-Key}：网络重试沿用同一键时原样返回首次结果，
     * 不会产生第二条消息、也不会让会话 {@code last_seq} 多走一格（R7）。</p>
     *
     * @param conversationId 会话 ID（路径参数）
     * @param request        发送入参（只含正文）
     * @param httpRequest    当前请求（取登录态）
     * @return {@link MessageSendResponse}（消息 ID + 会话 ID + 序号 + 发送时刻）
     */
    @PostMapping("/conversations/{conversation_id}/messages")
    @Idempotent
    public MessageSendResponse sendMessage(
            @PathVariable("conversation_id") Long conversationId,
            @Valid @RequestBody MessageSendRequest request,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return chatMessageService.sendText(userId, conversationId, request);
    }

    /**
     * 取登录用户 ID，未登录抛 {@code 40101}（范式同 {@code ContactController#requireUserId}）。
     *
     * @param request 当前请求
     * @return {@link Long} 登录用户 ID
     * @throws BizException {@code 40101}
     */
    private Long requireUserId(HttpServletRequest request) {
        Long userId = AuthContext.currentUserId(request);
        if (userId == null) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        return userId;
    }
}
