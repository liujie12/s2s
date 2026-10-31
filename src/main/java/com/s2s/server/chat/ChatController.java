package com.s2s.server.chat;

import com.s2s.server.chat.dto.ApplyDecisionRequest;
import com.s2s.server.chat.dto.ApplyStateResponse;
import com.s2s.server.chat.dto.ConversationCreateRequest;
import com.s2s.server.chat.dto.ConversationCreateResponse;
import com.s2s.server.chat.dto.ConversationPageResponse;
import com.s2s.server.chat.dto.MessagePageResponse;
import com.s2s.server.chat.dto.MessageSendRequest;
import com.s2s.server.chat.dto.MessageSendResponse;
import com.s2s.server.chat.dto.ReadResult;
import com.s2s.server.chat.dto.UnreadSummaryResponse;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.idempotency.Idempotent;
import com.s2s.server.common.web.AuthContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 会话域控制器（V30 / 计划 U2；详设 §5.5 的同构写法）。
 *
 * <p>职责：承载会话相关 HTTP 入口。本版有「开启或复用会话」「发送文本消息」两个写接口，
 * 以及会话列表、消息分页 / 增量、置已读三个读接口；申请审批（U6）、举报（U7）后续
 * 并入本控制器或各自的 {@code ChatQueryController}，路由前缀统一 {@code /conversations}。</p>
 *
 * <p>返回 DTO 由 {@code ResponseBodyWrapper} 统一套壳，本类不写 {@code ApiResponse}。</p>
 */
@RestController
public class ChatController {

    private final ChatService chatService;
    private final ChatMessageService chatMessageService;
    private final ChatQueryService chatQueryService;
    private final UnreadSummaryService unreadSummaryService;
    private final ContactApplyService contactApplyService;

    /**
     * 构造会话控制器。
     *
     * @param chatService          会话主链服务
     * @param chatMessageService   消息发送服务
     * @param chatQueryService     会话读取服务
     * @param unreadSummaryService 未读汇总唯一出口
     * @param contactApplyService  联系方式申请链路
     */
    public ChatController(ChatService chatService, ChatMessageService chatMessageService,
            ChatQueryService chatQueryService, UnreadSummaryService unreadSummaryService,
            ContactApplyService contactApplyService) {
        this.chatService = chatService;
        this.chatMessageService = chatMessageService;
        this.chatQueryService = chatQueryService;
        this.unreadSummaryService = unreadSummaryService;
        this.contactApplyService = contactApplyService;
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
     * 会话列表（{@code GET /conversations}，R3 / R4）。
     *
     * @param page        页码（可空，缺省 1）
     * @param pageSize    每页条数（可空；越界由 service 按 {@code ChatLimits} 钳制）
     * @param httpRequest 当前请求（取登录态）
     * @return {@link ConversationPageResponse} 当前页 + 总数
     */
    @GetMapping("/conversations")
    public ConversationPageResponse listConversations(
            @RequestParam(value = "page", required = false) Integer page,
            @RequestParam(value = "page_size", required = false) Integer pageSize,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return chatQueryService.listConversations(userId, page, pageSize);
    }

    /**
     * 会话内消息（{@code GET /conversations/{conversation_id}/messages}，R6）。
     *
     * <p>{@code after_seq} 与 {@code before_seq} 互斥：前者用于增量拉取，后者用于翻历史。</p>
     *
     * @param conversationId 会话 ID（路径参数）
     * @param beforeSeq      翻历史游标（可空）
     * @param afterSeq       增量游标（可空）
     * @param pageSize       每页条数（可空；越界由 service 钳制）
     * @param httpRequest    当前请求（取登录态）
     * @return {@link MessagePageResponse} 正序消息 + 是否还有更多
     */
    @GetMapping("/conversations/{conversation_id}/messages")
    public MessagePageResponse listMessages(
            @PathVariable("conversation_id") Long conversationId,
            @RequestParam(value = "before_seq", required = false) Integer beforeSeq,
            @RequestParam(value = "after_seq", required = false) Integer afterSeq,
            @RequestParam(value = "page_size", required = false) Integer pageSize,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return chatQueryService.listMessages(userId, conversationId, beforeSeq, afterSeq, pageSize);
    }

    /**
     * 置已读（{@code POST /conversations/{conversation_id}/read}，R10）。
     *
     * <p>打开会话即把全部消息标记为已读；水位只增不减，重复提交天然幂等，
     * 但仍声明 {@code @Idempotent} 以统一写接口的横切契约。</p>
     *
     * @param conversationId 会话 ID（路径参数）
     * @param httpRequest    当前请求（取登录态）
     * @return {@link ReadResult} 推进后的已读水位
     */
    @PostMapping("/conversations/{conversation_id}/read")
    @Idempotent
    public ReadResult markRead(@PathVariable("conversation_id") Long conversationId,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return chatQueryService.markRead(userId, conversationId);
    }

    /**
     * 未读汇总（{@code GET /unread-summary}，R8 / KTD9）。
     *
     * <p>Tab 角标、会话行红点与安卓桌面角标都读本接口，客户端不做二次求和。</p>
     *
     * @param httpRequest 当前请求（取登录态）
     * @return {@link UnreadSummaryResponse} 总数 + 会话未读 + 通知未读
     */
    @GetMapping("/unread-summary")
    public UnreadSummaryResponse unreadSummary(HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return unreadSummaryService.summary(userId);
    }

    /**
     * 提交（或再次提交）联系方式申请（{@code POST /conversations/{id}/apply}，R20 / R21）。
     *
     * @param conversationId 会话 ID（路径参数）
     * @param httpRequest    当前请求（取登录态）
     * @return {@link ApplyStateResponse} 提交后的卡片状态
     */
    @PostMapping("/conversations/{conversation_id}/apply")
    @Idempotent
    public ApplyStateResponse applyContact(@PathVariable("conversation_id") Long conversationId,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return contactApplyService.apply(userId, conversationId);
    }

    /**
     * 审批申请卡（{@code POST /conversations/{id}/apply/decision}，R21 / R22）。
     *
     * @param conversationId 会话 ID（路径参数）
     * @param request        审批入参（同意 / 拒绝）
     * @param httpRequest    当前请求（取登录态）
     * @return {@link ApplyStateResponse} 审批后的卡片状态
     */
    @PostMapping("/conversations/{conversation_id}/apply/decision")
    @Idempotent
    public ApplyStateResponse decideContactApply(
            @PathVariable("conversation_id") Long conversationId,
            @Valid @RequestBody ApplyDecisionRequest request,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return contactApplyService.decide(userId, conversationId, request);
    }

    /**
     * 查询申请卡状态（{@code GET /conversations/{id}/apply}，R21a / R24）。
     *
     * @param conversationId 会话 ID（路径参数）
     * @param httpRequest    当前请求（取登录态）
     * @return {@link ApplyStateResponse} 卡片状态与两个入口可用性
     */
    @GetMapping("/conversations/{conversation_id}/apply")
    public ApplyStateResponse contactApplyState(
            @PathVariable("conversation_id") Long conversationId,
            HttpServletRequest httpRequest) {
        Long userId = requireUserId(httpRequest);
        return contactApplyService.state(userId, conversationId);
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
