package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;

/**
 * {@link PostStatus} 状态派生与筛选口径测试（[127]）。
 *
 * <p>覆盖：库内 (status, status_reason) → API 值映射（[127] 用户裁定「库为真源 +
 * status_reason 派生」）、筛选逆映射、Batch1 不变量（draft 属 fail-fast）。</p>
 */
class PostStatusTest {

    @Test
    void active映射为active() {
        assertThat(PostStatus.toApi("active", null)).isEqualTo("active");
    }

    @Test
    void archived按reason派生offlineExpiredArchived() {
        // 用户主动下架（reason=0）→ offline
        assertThat(PostStatus.toApi("archived", 0)).isEqualTo("offline");
        // 审核下架（reason=2）→ offline
        assertThat(PostStatus.toApi("archived", 2)).isEqualTo("offline");
        // 到期自动下架（reason=1）→ expired
        assertThat(PostStatus.toApi("archived", 1)).isEqualTo("expired");
        // 成交（reason=3）→ archived
        assertThat(PostStatus.toApi("archived", 3)).isEqualTo("archived");
    }

    @Test
    void archived归因缺失按offline呈现() {
        assertThat(PostStatus.toApi("archived", null)).isEqualTo("offline");
    }

    @Test
    void hidden映射为offline() {
        assertThat(PostStatus.toApi("hidden", null)).isEqualTo("offline");
    }

    @Test
    void draft触发failFast() {
        assertThatThrownBy(() -> PostStatus.toApi("draft", null))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("draft");
    }

    @Test
    void 未知状态触发failFast() {
        assertThatThrownBy(() -> PostStatus.toApi("bogus", null))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void gone判定仅active可见() {
        assertThat(PostStatus.isGoneForOthers("active")).isFalse();
        assertThat(PostStatus.isGoneForOthers("archived")).isTrue();
        assertThat(PostStatus.isGoneForOthers("hidden")).isTrue();
    }

    @Test
    void filterFor逆映射() {
        PostStatus.ApiStatusFilter offline = PostStatus.filterFor("offline");
        assertThat(offline.dbStatuses()).containsExactlyInAnyOrder("hidden", "archived");
        assertThat(offline.reasons()).containsExactlyInAnyOrder(0, 2);
        assertThat(offline.allowNullReason()).isTrue();

        PostStatus.ApiStatusFilter expired = PostStatus.filterFor("expired");
        assertThat(expired.dbStatuses()).containsExactly("archived");
        assertThat(expired.reasons()).containsExactly(1);
        assertThat(expired.allowNullReason()).isFalse();

        assertThat(PostStatus.filterFor(null)).isNull();
    }

    @Test
    void filterFor未知值failFast() {
        assertThatThrownBy(() -> PostStatus.filterFor("draft"))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void action合法性判定() {
        assertThat(PostStatus.isValidAction("offline")).isTrue();
        assertThat(PostStatus.isValidAction("republish")).isTrue();
        assertThat(PostStatus.isValidAction("renew")).isTrue();
        assertThat(PostStatus.isValidAction("delete")).isFalse();
    }

    /**
     * 筛选值白名单判定：{@code null}（未传）与四个 API 值合法，其余非法。
     *
     * <p>controller 据此回 {@code 40001}，避免非法筛选值落到 {@code filterFor} 的
     * fail-fast 而被全局兜底成 {@code 50001}（客户端会把它当可重试）。</p>
     *
     * @return void
     */
    @Test
    void 筛选值合法性判定() {
        assertThat(PostStatus.isValidFilter(null)).isTrue();
        assertThat(PostStatus.isValidFilter("active")).isTrue();
        assertThat(PostStatus.isValidFilter("offline")).isTrue();
        assertThat(PostStatus.isValidFilter("expired")).isTrue();
        assertThat(PostStatus.isValidFilter("archived")).isTrue();
        assertThat(PostStatus.isValidFilter("draft")).isFalse();
        assertThat(PostStatus.isValidFilter("unknown")).isFalse();
    }
}
