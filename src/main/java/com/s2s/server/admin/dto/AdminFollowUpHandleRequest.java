package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.Size;

/**
 * 待运营跟进队列处理入参（[153] B2-5 ⑥）。
 *
 * @param remark 处理备注（可空）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminFollowUpHandleRequest(
        @Size(max = 255) String remark) {
}
