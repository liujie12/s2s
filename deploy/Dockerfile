# ============================================================================
# S2S Spring Boot 应用 Dockerfile — 多阶段构建
# ----------------------------------------------------------------------------
# 依据：《部署架构设计文档》§2.2 Dockerfile 构建策略
#       《技术栈选型说明》§3.1 Maven 定案（mvn -DskipTests package）
#       《DevSecOps 接入方案》§7.1 版本锁定（基础镜像用明确 tag）
#
# 纪律（违反即部署门禁失败）：
#   1. 运行镜像【禁止】包含 Maven 等构建工具
#      注：curl 是例外 —— 它是基础镜像 eclipse-temurin:21-jre-alpine 自带的
#      （实测 /usr/bin/curl 存在，wget 不存在），且 compose 的 healthcheck 依赖它。
#      不要为了「精简」去删它，删掉后健康检查永远失败，caddy 会一直等不到 app healthy。
#   2. 【禁止】COPY .env（见《部署架构设计文档》§7.3 纪律②）
#   3. 基础镜像必须使用明确 tag，【禁止】latest / RELEASE / 版本范围
#
# 前置条件（Batch1 编码期交付物，当前尚不存在）：
#   本文件依赖项目根目录存在 pom.xml 与 src/ 目录。在 Java 工程落地前，
#   docker compose build app 必然失败（COPY pom.xml 找不到文件）。
#   这不是 Dockerfile 的缺陷，而是编码阶段的依赖顺序。详见《部署架构设计文档》§2.2。
# ============================================================================

# -- 阶段一：编译 -----------------------------------------------------------------
# 使用 Maven 3 + Eclipse Temurin 21 作为构建环境
FROM maven:3.9-eclipse-temurin-21 AS builder

WORKDIR /build

# 先复制依赖描述文件，利用 Docker 层缓存减少重复下载
COPY pom.xml .
RUN mvn dependency:go-offline -B -q

# 复制源码并编译
COPY src ./src
RUN mvn -DskipTests package -B -q

# -- 阶段二：运行 -----------------------------------------------------------------
# 使用 Eclipse Temurin 21 JRE（Alpine 版）作为运行环境，体积约 200MB
FROM eclipse-temurin:21-jre-alpine

# 版本号从构建参数注入。必须显式声明 ARG：LABEL 只会展开【已声明】的构建参数，
# 未声明时 ${APP_VERSION:-latest} 会被写成字面量 latest（已实测确认）。
ARG APP_VERSION=latest

LABEL maintainer="s2s-dev" \
      description="S2S Spring Boot 3 应用" \
      version="${APP_VERSION}"

# 创建非 root 运行用户（安全最佳实践）
RUN addgroup -S s2s && adduser -S s2s -G s2s

WORKDIR /opt/s2s

# 仅从 builder 阶段复制构建产物，不复制源码
# 镜像内【禁止】出现 .env 文件
COPY --from=builder /build/target/*.jar ./app.jar

# 创建日志目录并授权给非 root 用户
RUN mkdir -p /var/log/app && chown -R s2s:s2s /var/log/app /opt/s2s

USER s2s

# 健康检查端点由 Caddy 在此端口上反向代理，不从容器外直接访问
EXPOSE 8080

# JVM 参数：
#   -Xmx600m — 内存预算上限（见《部署架构设计文档》§3.1 内存预算表）
#   -Djava.security.egd=file:/dev/./urandom — 加速 Tomcat 启动（Alpine 熵池）
#   -Dfile.encoding=UTF-8 — 统一字符编码
ENV JAVA_OPTS="-Xmx600m -Djava.security.egd=file:/dev/./urandom -Dfile.encoding=UTF-8"

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar /opt/s2s/app.jar"]