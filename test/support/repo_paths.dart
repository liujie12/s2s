/// 测试脚手架：仓库路径解析。
///
/// `flutter test` 的工作目录恒为包根（pubspec.yaml 所在目录），
/// 但不同 Dart 版本对相对路径基准的处理有过差异，且门禁测试需要
/// 反复定位 lib / docs / deploy 等目录，统一在此解析为绝对路径，
/// 避免每个测试各写一份 `'../../xxx'`。
library;

import 'dart:io';

/// 仓库根目录（包根即仓库根：pubspec.yaml 与 .git 同在该目录）。
///
/// 返回：[Directory] 仓库根，供其他路径拼接使用。
final Directory repoRoot = Directory.current.absolute;

/// 契约文件：docs/api/openapi.yaml。
///
/// 返回：[File] OpenAPI 契约文件，契约守门测试与契约测试示范共用。
final File openapiSpecFile = File(
  '${repoRoot.path}${Platform.pathSeparator}docs'
  '${Platform.pathSeparator}api'
  '${Platform.pathSeparator}openapi.yaml',
);

/// 客户端源码目录：lib/。
///
/// 返回：[Directory] lib 目录，源码层红线扫描的根。
final Directory libDir = Directory('${repoRoot.path}${Platform.pathSeparator}lib');

/// 部署脚本目录：deploy/scripts/。
///
/// 返回：[Directory] 部署门禁脚本目录，执行位检查的对象。
final Directory deployScriptsDir = Directory(
  '${repoRoot.path}${Platform.pathSeparator}deploy'
  '${Platform.pathSeparator}scripts',
);

/// 取仓库内任意相对路径对应的 [File]。
///
/// 功能：路径拼接的唯一实现处——各测试不得再手写
/// `'${repoRoot.path}${Platform.pathSeparator}...'`（评审 #12：
/// 同一拼接逻辑出现 4 处即须收编，防分隔符处理漂移）。
///
/// 参数：[relPath] 相对仓库根的路径（`/` 分隔，内部归一化为平台分隔符）。
/// 返回：[File] 指向该路径的文件对象（不保证存在，调用方自行判断）。
File repoFile(String relPath) => File(
      '${repoRoot.path}${Platform.pathSeparator}'
      '${relPath.replaceAll('/', Platform.pathSeparator)}',
    );

/// 断言仓库关键文件存在。
///
/// 功能：门禁测试在做任何扫描前先确认待判对象存在——
/// 这是《部署架构设计文档》§14.5 的固定句式：「先断言待判对象存在，
/// 再执行判据」。对象缺失时扫描面为空，空扫描面给出的 PASS 是
/// 假阴性（与 gate-check.sh G2/G9 同型缺陷）。
///
/// 参数：无（路径由本文件常量给出）。
/// 返回：void；任一关键路径缺失时抛出 [StateError]，测试即失败而非跳过。
void assertRepoLayout() {
  final missing = <String>[
    if (!openapiSpecFile.existsSync()) openapiSpecFile.path,
    if (!libDir.existsSync()) libDir.path,
    if (!deployScriptsDir.existsSync()) deployScriptsDir.path,
  ];
  if (missing.isNotEmpty) {
    throw StateError(
      '仓库关键路径缺失，门禁扫描面不完整（不得在空扫描面上报通过）：\n'
      '${missing.join('\n')}',
    );
  }
}
