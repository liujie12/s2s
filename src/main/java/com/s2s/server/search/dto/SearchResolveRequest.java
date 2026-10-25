package com.s2s.server.search.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 语义搜索解析入参（{@code POST /search/resolve}）。
 *
 * <p>输入可组合：文字（{@code text}）、客户端已转写文本（{@code voiceText}）、
 * 登录态语音媒体（{@code voiceMediaId}）、游客语音 base64（{@code voiceAudioBase64}）。
 * 地点锚点优先取长按点（{@code anchorLng/anchorLat}），其次文本地名，最后当前定位
 * （{@code currentLng/currentLat}）。全部字段可空，但至少一项文本/语音输入非空，
 * 否则服务端回 {@code 40001}。</p>
 *
 * @param text             文字输入（搜索框）
 * @param voiceText        客户端已转写的语音文本（优先于服务端 ASR）
 * @param voiceMediaId     登录态语音媒体 ID（服务端签名后 ASR，转写后即弃）
 * @param voiceAudioBase64 游客语音 base64（不落 OSS，直接进上游 ASR）
 * @param voiceContentType 游客语音 MIME（缺省 {@code audio/mp4}）
 * @param anchorLng        长按地图锚点经度（GCJ-02）
 * @param anchorLat        长按地图锚点纬度（GCJ-02）
 * @param currentLng       当前定位经度（无地名、无长按时兜底）
 * @param currentLat       当前定位纬度
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record SearchResolveRequest(
        String text,
        String voiceText,
        String voiceMediaId,
        String voiceAudioBase64,
        String voiceContentType,
        Double anchorLng,
        Double anchorLat,
        Double currentLng,
        Double currentLat) {
}
