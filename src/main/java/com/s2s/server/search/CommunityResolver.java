package com.s2s.server.search;

import com.s2s.server.common.constants.NfrSearch;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import org.springframework.stereotype.Component;

/**
 * 小区实体归一（口语地址 → 小区 ID）。
 *
 * <p><b>为什么不用向量</b>：「新徽苑」「鑫徽苑」「徽苑小区」在语义上很近，但它们是
 * <b>不同实体</b>。地址匹配要的是实体归一（选对那一个小区），不是相似度排序；
 * 用高德输入提示把候选收敛到住宅区，再用确定性打分 + 用户确认落定。</p>
 *
 * <p><b>口径</b>：归一化后完全相等或互相包含（去掉「北城」这类前缀）→ 直接采用；
 * 仅编辑距离接近（同音错字）→ <b>不猜</b>，回显候选让用户点选。</p>
 */
@Component
public class CommunityResolver {

    private final AmapPoiClient amapPoiClient;

    /**
     * 构造小区解析器。
     *
     * @param amapPoiClient 高德 Web 服务客户端
     */
    public CommunityResolver(AmapPoiClient amapPoiClient) {
        this.amapPoiClient = amapPoiClient;
    }

    /**
     * 解析口语地点为小区实体。
     *
     * @param keyword    口语地点（如「北城新徽苑」）
     * @param cityAdcode 城市 adcode（可空；非空时限制在该城市）
     * @return {@link CommunityMatch} 命中结果与候选；无 Key/无候选时返回空结果
     */
    public CommunityMatch resolve(String keyword, String cityAdcode) {
        if (keyword == null || keyword.isBlank()) {
            return CommunityMatch.empty();
        }
        String query = normalize(keyword);
        List<ScoredTip> scored = new ArrayList<>();
        for (AmapPoiClient.Tip tip : amapPoiClient.inputTips(keyword, cityAdcode)) {
            double score = score(query, normalize(tip.name()));
            if (score >= NfrSearch.COMMUNITY_MIN_SCORE) {
                scored.add(new ScoredTip(tip, score));
            }
        }
        scored.sort(Comparator.comparingDouble(ScoredTip::score).reversed());
        List<CommunityCandidate> candidates = new ArrayList<>();
        for (int i = 0; i < Math.min(NfrSearch.COMMUNITY_CANDIDATE_LIMIT, scored.size()); i++) {
            AmapPoiClient.Tip tip = scored.get(i).tip();
            candidates.add(new CommunityCandidate(tip.id(), tip.name(), tip.district(),
                    tip.lng(), tip.lat()));
        }
        if (scored.isEmpty()) {
            return CommunityMatch.empty();
        }
        ScoredTip top = scored.get(0);
        if (top.score() >= NfrSearch.COMMUNITY_AUTO_ACCEPT_SCORE) {
            AmapPoiClient.Tip tip = top.tip();
            return new CommunityMatch(tip.id(), tip.name(), tip.lng(), tip.lat(), candidates);
        }
        // 低置信：不静默采用，交给用户从候选里点选
        return new CommunityMatch(null, null, null, null, candidates);
    }

    /**
     * 名称归一：全角转半角、去空白与常见标点、转小写。
     *
     * @param raw 原始名称
     * @return {@link String} 归一化名称
     */
    String normalize(String raw) {
        if (raw == null) {
            return "";
        }
        StringBuilder builder = new StringBuilder(raw.length());
        for (char ch : raw.toCharArray()) {
            char normalizedChar = ch;
            if (ch >= '！' && ch <= '～') {
                normalizedChar = (char) (ch - 0xFEE0);
            }
            if (normalizedChar == '　' || Character.isWhitespace(normalizedChar)) {
                continue;
            }
            if ("()（）[]【】·-—_".indexOf(normalizedChar) >= 0) {
                continue;
            }
            builder.append(normalizedChar);
        }
        return builder.toString().toLowerCase(java.util.Locale.ROOT);
    }

    /**
     * 名称相似度：完全相等 1.0；互相包含 0.85；其余按编辑距离折算。
     *
     * <p>包含关系给 0.85 是为了覆盖「北城新徽苑 → 新徽苑」这类前缀口语；
     * 同音错字（鑫/新）编辑距离只差 1，得分通常低于 0.8，会落到候选确认分支。</p>
     *
     * @param query     归一化后的查询名
     * @param candidate 归一化后的候选名
     * @return double 0–1 相似度；任一为空返回 0
     */
    double score(String query, String candidate) {
        if (query.isEmpty() || candidate.isEmpty()) {
            return 0;
        }
        if (query.equals(candidate)) {
            return 1.0;
        }
        if (query.contains(candidate) || candidate.contains(query)) {
            return 0.85;
        }
        int maxLength = Math.max(query.length(), candidate.length());
        int distance = editDistance(query, candidate);
        return Math.max(0, 1.0 - (double) distance / maxLength);
    }

    /**
     * Levenshtein 编辑距离（滚动数组实现，长度量级为小区名，无需优化）。
     *
     * @param left  字符串 A
     * @param right 字符串 B
     * @return int 编辑距离
     */
    private int editDistance(String left, String right) {
        int[] previous = new int[right.length() + 1];
        int[] current = new int[right.length() + 1];
        for (int j = 0; j <= right.length(); j++) {
            previous[j] = j;
        }
        for (int i = 1; i <= left.length(); i++) {
            current[0] = i;
            for (int j = 1; j <= right.length(); j++) {
                int cost = left.charAt(i - 1) == right.charAt(j - 1) ? 0 : 1;
                current[j] = Math.min(Math.min(current[j - 1] + 1, previous[j] + 1),
                        previous[j - 1] + cost);
            }
            int[] swap = previous;
            previous = current;
            current = swap;
        }
        return previous[right.length()];
    }

    /**
     * 打分后的候选（内部排序用）。
     *
     * @param tip   高德候选
     * @param score 相似度
     */
    private record ScoredTip(AmapPoiClient.Tip tip, double score) {
    }

    /**
     * 小区解析结果。
     *
     * @param communityId 自动采用的小区 ID（低置信时为 null）
     * @param communityName 自动采用的小区规范名（低置信时为 null）
     * @param lng 小区质心经度（低置信时为 null）
     * @param lat 小区质心纬度（低置信时为 null）
     * @param candidates 候选列表（最多 {@code NfrSearch.COMMUNITY_CANDIDATE_LIMIT} 个）
     */
    public record CommunityMatch(String communityId, String communityName, Double lng, Double lat,
            List<CommunityCandidate> candidates) {

        /**
         * 空结果。
         *
         * @return {@link CommunityMatch} 无命中
         */
        public static CommunityMatch empty() {
            return new CommunityMatch(null, null, null, null, List.of());
        }
    }

    /**
     * 小区候选（回显给用户点选）。
     *
     * @param id       高德 POI ID
     * @param name     规范名
     * @param district 所属区县
     * @param lng      经度
     * @param lat      纬度
     */
    public record CommunityCandidate(String id, String name, String district, double lng, double lat) {
    }
}
