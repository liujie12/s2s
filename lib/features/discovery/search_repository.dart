/// 语义搜索仓库（地图语音语义搜索 U5）：`POST /search/resolve`。
///
/// 与其它仓库同一模式：真网络走 [dioProvider] 生产同款五拦截器链；本层只做
/// 「发请求 + 交 DTO 解析」，信封由 EnvelopeInterceptor 拆、业务错误以
/// [ApiException] 抛出，本层不吞不改写。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import 'search_intent.dart';

/// 语义搜索仓库。
class SearchRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio。
  SearchRepository(this._dio);

  final Dio _dio;

  /// 解析一句话搜索意图（文字或语音）。
  ///
  /// 参数：
  /// - [text] 文字输入（可空）；
  /// - [voiceMediaId] 登录态音频媒体 ID（可空，服务端签名后 ASR）；
  /// - [voiceBase64] 游客音频 base64（可空，不落 OSS）；
  /// - [voiceContentType] 游客音频 MIME（可空，后端缺省 audio/mp4）；
  /// - [anchorLat]/[anchorLng] 长按地图锚点（可空）；
  /// - [currentLat]/[currentLng] 当前定位（可空）。
  /// 返回：[SearchIntent] 槽位卡。
  /// 抛出：[ApiException] 信封业务错误（40001/42901/50301）与解析失败。
  Future<SearchIntent> resolve({
    String? text,
    String? voiceMediaId,
    String? voiceBase64,
    String? voiceContentType,
    double? anchorLat,
    double? anchorLng,
    double? currentLat,
    double? currentLng,
  }) async {
    final payload = <String, Object?>{
      if (text != null && text.trim().isNotEmpty) 'text': text.trim(),
      'voice_media_id': ?voiceMediaId,
      'voice_audio_base64': ?voiceBase64,
      'voice_content_type': ?voiceContentType,
      'anchor_lat': ?anchorLat,
      'anchor_lng': ?anchorLng,
      'current_lat': ?currentLat,
      'current_lng': ?currentLng,
    };
    // 解析是「语音 ASR + 词表 + 可能 AI 兜底」的组合链路，按全局 10s 读超时；
    // 不套 AI 发布那档 5s（那条链路有骨架屏兜底，本链路失败即整句不可用）。
    final response = await _dio.post<Object?>('/search/resolve', data: payload);
    return SearchIntent.fromJson(response.data);
  }
}

/// 语义搜索仓库 Provider（dio 经 [dioProvider] 注入，与生产装配同源）。
final searchRepositoryProvider = Provider<SearchRepository>(
  (ref) => SearchRepository(ref.watch(dioProvider)),
);
