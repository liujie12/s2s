package com.s2s.server.post;

import com.s2s.server.common.web.AuthContext;
import com.s2s.server.post.dto.MediaCommitResult;
import com.s2s.server.post.dto.UploadTicket;
import com.s2s.server.post.dto.UploadTicketRequest;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * 媒体域控制器（[125]；详设 §5.3.1 媒体两步式直传）。
 *
 * <p>职责：承载 media 域 HTTP 入口——{@code POST /media/upload/ticket}（票据签发）、
 * {@code POST /media/{media_id}/commit}（提交确认）。返回 DTO 由
 * {@code ResponseBodyWrapper} 统一套壳。</p>
 */
@RestController
public class MediaController {

    private final MediaService mediaService;

    /**
     * 构造媒体域控制器。
     *
     * @param mediaService 媒体服务
     */
    public MediaController(MediaService mediaService) {
        this.mediaService = mediaService;
    }

    /**
     * 申请 OSS 直传票据（两步式第 1 步）。
     *
     * @param request     票据请求（filename + size + content_type）
     * @param httpRequest 当前请求（取登录用户 ID）
     * @return {@link UploadTicket}（media_id + upload_url + expire_at）
     */
    @PostMapping("/media/upload/ticket")
    public UploadTicket createUploadTicket(@Valid @RequestBody UploadTicketRequest request,
            HttpServletRequest httpRequest) {
        Long userId = AuthContext.currentUserId(httpRequest);
        return mediaService.createTicket(userId, request.filename(), request.size(), request.contentType());
    }

    /**
     * 确认媒体上传完成（两步式第 2 步）。
     *
     * @param mediaId     媒体 ID（路径参数）
     * @param httpRequest 当前请求（取登录用户 ID）
     * @return {@link MediaCommitResult}（media_id + url + audit_status）
     */
    @PostMapping("/media/{media_id}/commit")
    public MediaCommitResult commitMedia(@PathVariable("media_id") String mediaId,
            HttpServletRequest httpRequest) {
        Long userId = AuthContext.currentUserId(httpRequest);
        return mediaService.commit(userId, mediaId);
    }
}
