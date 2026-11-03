package com.s2s.server.chat;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * 会话三表与既有表扩展的迁移契约门禁（V30；计划 U1）。
 *
 * <p><b>为什么用「读迁移文件断言」而不是连库</b>：本仓库的单元测试不接数据库
 * （无 {@code src/test/resources}、无测试库装配），迁移的「空库可执行」由本地
 * {@code mvn flyway} 与部署链路验证；本测试守的是<b>结构口径</b>——唯一键、
 * 水位列、枚举取值这些一旦写错就会在运行时静默出错的东西（例如漏了
 * {@code uk_post_initiator}，同一帖子会冒出第二条会话）。</p>
 *
 * <p>与 {@code MapperScanCoverageTest} 同范式：直读源码树文件，断言失败即点名缺项。</p>
 */
class ChatSchemaTest {

    /** 测试工作目录为仓库根（同 {@code MapperScanCoverageTest} 约定）。 */
    private static final Path MIGRATION =
            Path.of("src", "main", "resources", "db", "migration",
                    "V30__conversation_and_message.sql");

    /**
     * 三张表与关键结构齐备。
     *
     * @throws IOException 迁移文件不可读时抛出（读不到即扫描面失真，不得当作通过）
     */
    @Test
    @DisplayName("V30 建齐 conversation / conversation_member / message 及其唯一键与水位列")
    void createsThreeTablesWithUniqueKeysAndWatermark() throws IOException {
        String sql = readMigration();

        assertThat(sql).as("会话表").contains("CREATE TABLE `conversation`");
        assertThat(sql)
                .as("同一帖子与同一发起人唯一（R5：永不出现第二条会话）")
                .contains("UNIQUE KEY `uk_post_initiator` (`post_id`, `initiator_id`)");
        assertThat(sql).as("会话内序号水位").contains("`last_seq`");
        assertThat(sql).as("申请卡状态挂会话行（KTD2）").contains("`apply_status`");

        assertThat(sql).as("成员表").contains("CREATE TABLE `conversation_member`");
        assertThat(sql)
                .as("已读水位是未读唯一真源（KTD1）")
                .contains("`last_read_seq`");
        assertThat(sql)
                .as("未读期间已推送标记（KTD7）")
                .contains("`pushed_unread`");
        assertThat(sql)
                .as("成员复合主键")
                .contains("PRIMARY KEY (`conversation_id`, `user_id`)");

        assertThat(sql).as("消息表").contains("CREATE TABLE `message`");
        assertThat(sql)
                .as("会话内序号唯一（KTD3：并发不重号不漏号）")
                .contains("UNIQUE KEY `uk_conversation_seq` (`conversation_id`, `seq`)");
        assertThat(sql)
                .as("三类消息同表")
                .contains("ENUM('text','apply','contact')");
        assertThat(sql)
                .as("联系方式卡只对申请人可见（R22）")
                .contains("`visible_to`");
    }

    /**
     * 既有表扩展齐备：帖子申请开关、联系事件渠道与会话列、举报误拦值、用户设置开关、总开关种子。
     *
     * @throws IOException 迁移文件不可读时抛出
     */
    @Test
    @DisplayName("V30 扩展既有表：需申请列、会话渠道、误拦原因、消息通知开关与总开关种子")
    void extendsExistingTables() throws IOException {
        String sql = readMigration();

        assertThat(sql).as("帖子：需申请开关（R19）").contains("`contact_apply_required`");
        assertThat(sql)
                .as("联系事件：渠道扩会话/申请两值（KTD11）")
                .contains("ENUM('phone','wechat','conversation','apply')");
        assertThat(sql)
                .as("联系事件：会话标识（一个会话只写一条）")
                .contains("`conversation_id`");
        assertThat(sql).as("举报：误拦原因值（R28）").contains("'misblock'");
        assertThat(sql).as("用户设置：独立的消息通知开关（R15）").contains("`notify_message`");
        assertThat(sql)
                .as("系统配置：消息总开关种子值（R30）")
                .contains("'message_enabled'");
    }

    /**
     * V33：conversation_member 增加 deleted_at，承载「仅自己删除会话」。
     *
     * @throws IOException 迁移文件不可读时抛出
     */
    @Test
    @DisplayName("V33 增加 conversation_member.deleted_at：仅自己删除、可被新消息唤醒")
    void addsMemberDeletedAtForUserLevelRemoval() throws IOException {
        Path migration = Path.of("src", "main", "resources", "db", "migration",
                "V33__conversation_member_deleted_at.sql");
        assertThat(Files.isRegularFile(migration))
                .as("V33 迁移文件必须存在（缺失会让删除接口启动即失败）")
                .isTrue();

        String sql = Files.readString(migration, StandardCharsets.UTF_8);
        assertThat(sql)
                .as("只给成员表加列：删除是仅本人口径，不动会话与消息")
                .contains("ALTER TABLE `conversation_member`");
        assertThat(sql).as("可见性列").contains("`deleted_at`");
    }

    /**
     * 迁移版本号唯一：同版本号会让 Flyway 在启动期直接失败。
     *
     * @throws IOException 迁移目录不可读时抛出
     */
    @Test
    @DisplayName("迁移版本号唯一：V30 不与任何既有版本重号")
    void migrationVersionIsUnique() throws IOException {
        Path directory = MIGRATION.getParent();
        List<String> sameVersion;
        try (var paths = Files.list(directory)) {
            sameVersion = paths
                    .map(path -> path.getFileName().toString())
                    .filter(name -> name.startsWith("V30__"))
                    .toList();
        }
        assertThat(sameVersion)
                .as("V30 只能有一个迁移文件（重号会让 Flyway 启动失败）")
                .containsExactly(MIGRATION.getFileName().toString());
    }

    /**
     * 读取 V30 迁移全文。
     *
     * @return {@link String} 迁移 SQL 文本
     * @throws IOException 文件缺失或不可读时抛出
     */
    private String readMigration() throws IOException {
        assertThat(Files.isRegularFile(MIGRATION))
                .as("迁移文件 %s 必须存在", MIGRATION)
                .isTrue();
        return Files.readString(MIGRATION, StandardCharsets.UTF_8);
    }
}
