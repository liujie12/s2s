/// 质量门禁测试（代码面）：CI 与本地共用同一份判据。
///
/// 依据：《DevSecOps 接入方案》§4.1（后门剔除源码层）、§7.3（密钥泄露 L1）、
///       条目 [108] S6 裁决（CI 只承载代码面判据）、
///       条目 [109]~[112]（门禁四态：判不了不得报通过）。
///
/// 三道门：
///   G-Q1 后门码登记册：lib/ 中每个 `888888` 字面量必须在此登记，
///         登记册中的每条必须仍能在 lib/ 中找到——双向核对，
///         防「新增后门未登记」也防「后门已删但登记册留着凑数」。
///   G-Q2 密钥泄露扫描：git 跟踪的文本文件中不得出现私钥 PEM 头 /
///         阿里云 AK / 高德 Web 服务 Key 形态串（§7.3）。
///   G-Q3 部署脚本执行位：deploy/scripts/*.sh 在 git 索引中必须是 100755。
///
/// 这些判据全部只依赖代码与 git 索引，不依赖 docker / 域名 / 运行环境，
/// 因此可在 CI runner 上真实判定；部署面门禁（G1–G11）不在此处，
/// 进 CI 只会全部 SKIP 而制造绿勾假象（S6 裁决已明确排除）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/repo_paths.dart';

/// 一条后门码登记。
class RegisteredBackdoor {
  const RegisteredBackdoor({
    required this.file,
    required this.lineContains,
    required this.reason,
    required this.removeWhen,
  });

  /// 相对仓库根的文件路径，如 `lib/features/auth/auth_repository.dart`。
  final String file;

  /// 命中行必须包含的子串（用于在文件内定位，避免行号漂移）。
  final String lineContains;

  /// 为什么现在允许它存在（接后端前的联调用途）。
  final String reason;

  /// 什么条件下必须删除（删除后本登记条目一并移除）。
  final String removeWhen;
}

/// 后门码登记册。
///
/// 规格（DevSecOps §4.1 源码层）：命中行必须可逐处人工确认；
/// 无法确认即失败。登记册把「人工确认」固化成代码评审可见的条目，
/// 每条都写明存在理由与删除条件。**新增任何 888888 字面量而不在此登记，
/// G-Q1 立即失败**——这正是这道门要拦的动作。
const List<RegisteredBackdoor> registeredBackdoors = [
  RegisteredBackdoor(
    file: 'lib/features/auth/auth_repository.dart',
    lineContains: "_debugCode = '888888'",
    reason: '接短信通道前的本地联调固定验证码（无真实短信通道时登录页无法自测）',
    removeWhen: '接入服务端登录接口、验证码改由短信下发时删除（TODO(接后端) 已标注于引用处）',
  ),
];

/// 一条已人工确认的密钥命中豁免登记。
///
/// 与 [registeredBackdoors] 同构：豁免不是关闭判据，而是把「此处为什么允许命中」
/// 固化成代码评审可见的留证（DevSecOps §3.2 四要素：执行者/工具/失败判定/留证方式）。
/// 每条必须写明处置条件；双向核对防凑数（登记了但代码里找不到即 FAIL）。
class RegisteredSecretFinding {
  const RegisteredSecretFinding({
    required this.file,
    required this.lineContains,
    required this.provider,
    required this.reason,
    required this.remediation,
  });

  /// 相对仓库根的文件路径。
  final String file;

  /// 命中行必须包含的子串（用于定位，避免行号漂移）。
  final String lineContains;

  /// 密钥归属方（哪家平台、什么 Key），便于日后定向作废。
  final String provider;

  /// 为什么当前允许该命中留在仓库中。
  final String reason;

  /// 彻底消除条件（通常是「控制台作废 → 代码替换为占位符 → 移除本登记」）。
  final String remediation;
}

/// 密钥命中豁免登记册。
///
/// 以下 6 处均位于 prototype/——需求阶段的 HTML/JS 交互原型，不随 Flutter App
/// 编译、不进 Docker 镜像，属一次性演示资产。**但 key 已进入 git 历史，
/// 删除代码不等于撤销泄露**，故每条 remediation 都如实标注：唯一彻底处置是
/// 到对应云控制台作废更换。新增密钥命中而不在此登记，G-Q2 立即失败。
const List<RegisteredSecretFinding> registeredSecretFindings = [
  RegisteredSecretFinding(
    file: 'prototype/pathDetail.html',
    lineContains: 'aa6ff0d9da3a35cd35b8d192a00d1d85',
    provider: '高德地图 Web 端 Key',
    reason: '早期交互原型地图页联调用 key；prototype 不随 App/镜像交付',
    remediation: '须到高德控制台作废该 Key；作废后将代码替换为 YOUR_AMAP_KEY 占位并移除本登记',
  ),
  RegisteredSecretFinding(
    file: 'prototype/search.js',
    lineContains: 'sk-f2885e8725e04ec690db459cea8bcc57',
    provider: '火山方舟（豆包/千问兼容接口）API Key',
    reason: '早期交互原型搜索页联调用 key（注释注明「用户提供的API密钥」）；不随 App/镜像交付',
    remediation: '须到火山方舟控制台作废该 Key；作废后替换为占位符并移除本登记',
  ),
  RegisteredSecretFinding(
    file: 'prototype/semanticProcessingSystem.js',
    lineContains: 'sk-f2885e8725e04ec690db459cea8bcc57',
    provider: '火山方舟（豆包/千问兼容接口）API Key',
    reason: '早期交互原型语义处理模块默认 key；不随 App/镜像交付',
    remediation: '须到火山方舟控制台作废该 Key；作废后替换为占位符并移除本登记',
  ),
  RegisteredSecretFinding(
    file: 'prototype/smartParse.js',
    lineContains: 'sk-f2885e8725e04ec690db459cea8bcc57',
    provider: '火山方舟（豆包/千问兼容接口）API Key',
    reason: '早期交互原型智能解析模块硬编码 key；不随 App/镜像交付',
    remediation: '须到火山方舟控制台作废该 Key；作废后替换为占位符并移除本登记',
  ),
  RegisteredSecretFinding(
    file: 'prototype/index.html',
    lineContains: '9c4af3b304f2138ff4a7e55c470f69d3',
    provider: '高德地图 Web 服务 Key（securityJsCode 与 JS API 同串）',
    reason: '早期交互原型主页地图联调用 key；不随 App/镜像交付。'
        'ce-code-review 2026-09-10 发现：该文件超 512KB，被旧扫描上限静默跳扫，'
        '此命中此前漏登（评审 #1）',
    remediation: '须到高德控制台作废该 Key；作废后将代码替换为 YOUR_AMAP_KEY 占位并移除本登记',
  ),
  RegisteredSecretFinding(
    file: 'prototype/test.html',
    lineContains: '9c4af3b304f2138ff4a7e55c470f69d3',
    provider: '高德地图 Web 服务 Key（securityJsCode 与 JS API 同串）',
    reason: '早期交互原型测试页地图联调用 key（与 index.html 同一串）；不随 App/镜像交付。'
        '同评审 #1：因 512KB 上限被静默跳扫而漏登',
    remediation: '须到高德控制台作废该 Key；作废后将代码替换为 YOUR_AMAP_KEY 占位并移除本登记',
  ),
];

/// 不参与密钥扫描的路径后缀/目录（依赖锁、生成物、第三方资产、二进制文档）。
bool isScanExcluded(String path) {
  final p = path.replaceAll('\\', '/');
  // 根级锚定（复审三 #3）：contains('/build/') 会连坐排除任意层级的
  // build/ 跟踪目录（如 lib/build/secrets.dart），静默缩水扫描面。
  // 单包仓库的构建产物只在根 build/；嵌套 build 源目录必须受扫。
  final isRootBuildDir = p == 'build' || p.startsWith('build/');
  return p.contains('.pydeps/') ||
      p.contains('/.dart_tool/') ||
      isRootBuildDir ||
      p.contains('pubspec.lock') ||
      p.contains('.agents/') ||
      p.contains('agent/skills/') ||
      p.endsWith('.png') ||
      p.endsWith('.jpg') ||
      p.endsWith('.jpeg') ||
      p.endsWith('.gif') ||
      p.endsWith('.webp') ||
      p.endsWith('.ico') ||
      p.endsWith('.ttf') ||
      p.endsWith('.otf') ||
      // 二进制文档/压缩包：UTF-8 逐行解码必抛或产出海量噪声字节，
      // 密钥不可能以可检索文本形态藏于此（评审 #6：.docx 整体解码必抛）。
      p.endsWith('.docx') ||
      p.endsWith('.pptx') ||
      p.endsWith('.xlsx') ||
      p.endsWith('.pdf') ||
      p.endsWith('.zip');
}

/// CI 环境判定（复审 #11：全文件唯一承载处，调用点不得再手写字面量比较）。
///
/// 谓词刻意放宽：`CI` 变量非空且非 'false' 即视为 CI——CI=1/TRUE/yes 等
/// 平台写法差异一并覆盖；字面值 == 'true' 会让非 'true' 写法在 git 失败时
/// 退回 markTestSkipped，而 SKIP 在 CI 报告里与绿勾同形，门禁静默落空。
/// 参数：[env] 环境变量表，缺省读取进程环境（注入点供判据自检测用）。
/// 返回：`bool`，判定为 CI 环境返回 true。
bool isCi([Map<String, String>? env]) {
  final ci = (env ?? Platform.environment)['CI'];
  return ci != null && ci.isNotEmpty && ci.toLowerCase() != 'false';
}

/// 「判不了」分支的唯一处置处（复审 #11）：CI 上必须红、本地记 SKIP。
///
/// CI 上判据对象不可得（如 git 失败）时 SKIP 与绿勾同形，必须 fail；
/// 本地非 git 环境允许 SKIP，但不许静默 PASS。
/// 覆盖登记：fail 分支在能跑起测试套的环境（必然有 git）自动化不可达，
/// 其正确性靠评审保证（复审 #11 裁决：登记于此，不伪造覆盖）。
/// 参数：[ciFailReason] CI 环境的失败原因；[localSkipReason] 本地 SKIP 原因。
/// 返回：void；CI 环境经 [fail] 抛 [TestFailure]，本地经 markTestSkipped 中止用例。
void skipOrFailOnCi({
  required String ciFailReason,
  required String localSkipReason,
}) {
  if (isCi()) fail(ciFailReason);
  markTestSkipped(localSkipReason);
}

/// 32 位 hex 串判据（大小写均命中：真实密钥不保证小写——评审 #10）。
///
/// 判据正则的唯一承载处，扫描主流程与判据自检共用，
/// 禁在各处复制字面量正则（防两处定义漂移）。
final RegExp hex32Pattern = RegExp(r'\b[0-9a-fA-F]{32}\b');

/// 判定一行文本是否命中「疑似密钥」弱判据（32 位 hex + 密钥语义上下文）。
///
/// 纯函数，便于对判据自身做变异/负向单测（正向跑通不构成证据，
/// 必须证明它对应当失败的输入真会失败——门禁准则 9.9）。
///
/// 参数：[line] 待判定的单行文本。
/// 返回：`bool`，命中返回 true。
bool looksLikeEmbeddedSecret(String line) {
  final trimmed = line.trim();
  final hasHex32 = hex32Pattern.hasMatch(line);
  // Dart RegExp 不支持内联 (?i)，大小写不敏感用 caseSensitive: false。
  final hasSecretContext =
      RegExp(r'(key|secret|token|amap|高德|password|passwd)',
              caseSensitive: false)
          .hasMatch(line);
  final isComment = trimmed.startsWith('//') || trimmed.startsWith('#');
  return hasHex32 && hasSecretContext && !isComment;
}

/// 32 位全同字符的 hex 串（aaaaaaaa.../bbbb.../cccc...）视为模板占位值。
///
/// `.example` 环境变量模板刻意使用此类假值（真实密钥是随机串，全同字符概率为 1/16^31）。
/// 参数：[hex] 已匹配出的 32 位 hex 字符串。返回：`bool`，是占位形态返回 true。
bool isRepeatedCharPlaceholder(String hex) =>
    hex.length == 32 && hex.split('').toSet().length == 1;

/// 同行相邻字符串字面量坍缩：把 `'abc' 'def'` / `"abc" "def"` / `'abc' + 'def'`
/// 形式的编译期拼接还原成单串，作为密钥扫描的附加候选行。
///
/// 背景（评审 #5，KTD6 绕过）：把 32 位 hex 拆成两段相邻字面量即可躲过
/// 逐行正则判据；坍缩通道让这种拆写在扫描视角下重新拼回完整串。
/// 文法放宽（复审 #3）：`+` 显式拼接是最常见的拆写形态，正则放行可选加号。
///
/// 参数：[line] 原始行文本。
/// 返回：`String` 坍缩后的候选行；无相邻字面量时与原行相等。
/// 注意：空字符串 `''` 也会被吃掉，故本函数产物只作附加扫描候选，
/// 原行仍是第一通道，两者互补。
/// 已知盲区（固化登记，复审 #3）：块注释夹隔（'a' /* x */ + 'b'）不还原。
String collapseAdjacentLiterals(String line) =>
    line.replaceAll(RegExp(r'''['"][ \t]*\+?[ \t]*['"]'''), '');

/// 跨行相邻字面量候选：上行以引号收尾、下行以引号开头时，
/// 去掉边界引号拼接两行内容（覆盖 KTD6 的跨行拆写形态，评审 #5）。
///
/// 文法放宽（复审 #3）：
///   - 不再要求同种引号——Dart 相邻字面量允许混用单双引号；
///   - 允许行尾/行首 `+` 显式拼接符（'abc' +\n'def' 与 'abc'\n+ 'def'）。
///
/// 参数：[prevLine] 上一行原文（文件首行传 null）；[line] 当前行原文。
/// 返回：`String?` 可拼接时返回拼接候选，否则 null。
/// 已知盲区（固化登记，复审 #3、复审三 #2）：3 行及以上拆分（11/11/10）、
/// 块注释夹隔（'a' /* x */ + 'b'）、行尾 `//` 行注释夹隔
/// （'a' // x\n'b'——词法上注释等价空白，仍为合法相邻字面量）不覆盖；
/// 判据自检以负向用例把盲区固化为可见已知限制。
String? crossLineCandidate(String? prevLine, String line) {
  if (prevLine == null) return null;
  var prev = prevLine.trimRight();
  // 行尾 `+` 显式拼接：'abc' +\n'def'。
  if (prev.endsWith('+')) {
    prev = prev.substring(0, prev.length - 1).trimRight();
  }
  var cur = line.trimLeft();
  // 行首 `+` 显式拼接：'abc'\n+ 'def'。
  if (cur.startsWith('+')) {
    cur = cur.substring(1).trimLeft();
  }
  if (prev.isEmpty || cur.isEmpty) return null;
  final prevQuote = prev[prev.length - 1];
  final curQuote = cur[0];
  // 混引号合法（Dart 相邻字面量不限同种引号，复审 #3）。
  if ((prevQuote == "'" || prevQuote == '"') &&
      (curQuote == "'" || curQuote == '"')) {
    return '${prev.substring(0, prev.length - 1)}${cur.substring(1)}';
  }
  return null;
}

/// 单个 32 位 hex 命中的三分支处置结论（复审 #4：处置粒度为「命中」而非「行」）。
enum SecretHitVerdict {
  /// 模板占位假值（aaaa.../cccc...），非真实密钥，跳过。
  placeholder,

  /// 已登记豁免（列名留证，不静默）。
  exempted,

  /// 未登记豁免的疑似密钥，记入 findings（FAIL）。
  unregistered,
}

/// 判断某个 32 位 hex 命中是否已被豁免登记册覆盖。
///
/// 收紧历史（复审 #4）：旧口径「行 contains 登记串」会把同行的新密钥连带
/// 豁免——同一已登记文件内与泄露串同行写 `BACKUP: '<新32hex>'` 直接变绿；
/// 现按「登记定位串 contains 当前命中 hex」逐命中判定，同行其余命中不受连带。
/// 参数：[relPath] 相对仓库根的文件路径；[hex] 本次命中的 32 位 hex 串。
/// 返回：`bool`，该命中被登记覆盖返回 true。
bool isRegisteredSecretHex(String relPath, String hex) =>
    registeredSecretFindings
        .any((r) => r.file == relPath && r.lineContains.contains(hex));

/// 对单个 32 位 hex 命中做三分支判定（占位 / 已登记豁免 / 未登记）。
///
/// 纯函数，判据自检可直接对每种分支做变异断言（复审 #4）。
/// 参数：[relPath] 相对仓库根的文件路径；[hex] 本次命中的 32 位 hex 串。
/// 返回：[SecretHitVerdict] 该命中的处置结论。
SecretHitVerdict classifySecretHex(String relPath, String hex) {
  if (isRepeatedCharPlaceholder(hex)) return SecretHitVerdict.placeholder;
  if (isRegisteredSecretHex(relPath, hex)) return SecretHitVerdict.exempted;
  return SecretHitVerdict.unregistered;
}

/// 判据自检样例串（统一承载，防各用例重复字面量）。
///
/// 变量命名刻意避开 key|secret|token|amap|高德|password|passwd 上下文词，
/// 使声明行自身不命中弱判据；使用处一律插值引用——源码行若直接写
/// 相邻字面量拆串，会被坍缩/跨行通道（评审 #5）把本文件自身判为命中。
const String _gaodeSample = 'aa6ff0d9da3a35cd35b8d192a00d1d85';
const String _skSample = 'sk-f2885e8725e04ec690db459cea8bcc57';

/// sk 样例的 32 位 hex 本体（剥离 sk- 前缀——hex32Pattern 实际命中的形态，
/// classifySecretHex/isRegisteredSecretHex 自检测用）。
const String _skHex32 = 'f2885e8725e04ec690db459cea8bcc57';
const String _hex16 = '0123456789abcdef';
const String _upperHexSample = '9C4AF3B304F2138FF4A7E55C470F69D3';

void main() {
  // 先断言仓库布局存在——扫描面为空时 PASS 是假阴性（gate-check G2/G9 同型缺陷）。
  setUpAll(assertRepoLayout);

  group('G-Q1 后门码 888888 登记册（DevSecOps §4.1 源码层）', () {
    /// 收集 lib/ 下所有 .dart 文件中含 888888 的行（逐行，含出现次数）。
    /// 返回：(相对路径, 行号, 行内 888888 出现次数, 行原文) 列表。
    List<({String file, int lineNo, int count, String line})>
        collectBackdoorLines() {
      final hits = <({String file, int lineNo, int count, String line})>[];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel =
            'lib/${entity.path.replaceAll('\\', '/').split('/lib/').last}';
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final count = RegExp('888888').allMatches(lines[i]).length;
          if (count > 0) {
            hits.add((file: rel, lineNo: i + 1, count: count, line: lines[i]));
          }
        }
      }
      return hits;
    }

    /// 判定一行内登记条目覆盖了几个 888888（复审三 #5）。
    ///
    /// 对命中本行的每个登记条目，从行文本中剥除一次其定位串后再数剩余
    /// 888888——剥除法让「同一登记串被多个条目重复登记」不会重复抵扣，
    /// 也让同行追加的第二个字面量在剥除后仍被数出。
    /// 参数：[file] 相对路径；[line] 行原文。
    /// 返回：`int` 未被登记覆盖的 888888 个数（0 表示全部已登记）。
    int uncoveredInLine(String file, String line) {
      var remaining = line;
      for (final b in registeredBackdoors) {
        if (b.file == file && remaining.contains(b.lineContains)) {
          remaining = remaining.replaceFirst(b.lineContains, '');
        }
      }
      return RegExp('888888').allMatches(remaining).length;
    }

    test('lib/ 中每个 888888 字面量都在登记册中有对应条目', () {
      final unregistered = <String>[];
      for (final hit in collectBackdoorLines()) {
        final uncovered = uncoveredInLine(hit.file, hit.line);
        if (uncovered > 0) {
          unregistered.add('${hit.file}:${hit.lineNo}: '
              '${hit.line.trim()}（该行 $uncovered/${hit.count} 处 888888 未登记）');
        }
      }
      expect(unregistered, isEmpty,
          reason: '发现未登记的 888888 后门码（DevSecOps §4.1：无法逐处确认即失败；'
              '同一登记行追加新字面量不得连坐豁免，复审三 #5）：\n'
              '${unregistered.join('\n')}\n'
              '若为正当联调用途，在 registeredBackdoors 登记并写明理由与删除条件；\n'
              '否则必须删除。产物层（release APK strings）另有出包门禁兜底。');
    });

    test('登记册中每条都仍在 lib/ 中存在（防留着凑数的过期登记）', () {
      final stale = <String>[];
      for (final b in registeredBackdoors) {
        final f = repoFile(b.file);
        if (!f.existsSync() ||
            !f.readAsLinesSync().any((l) => l.contains(b.lineContains))) {
          stale.add('${b.file}（${b.lineContains}）——后门已删但登记册未清；'
              '请同步移除该登记条目');
        }
      }
      expect(stale, isEmpty, reason: stale.join('\n'));
    });

    test('uncoveredInLine 剥除判定：登记位抵扣一次，同行追加不连坐（复审三 #5）', () {
      const f = 'lib/features/auth/auth_repository.dart';
      // 仅登记位一处 → 0 未覆盖
      expect(uncoveredInLine(f, "  String _debugCode = '888888';"), 0);
      // 同行追加第二个 888888 → 剥除登记串后仍剩 1 处，必须被数出
      expect(
          uncoveredInLine(f,
              "  String _debugCode = '888888'; const backup = '888888';"),
          1);
      // 不同文件不抵扣
      expect(uncoveredInLine('lib/other.dart', "_debugCode = '888888'"), 1);
    });
  });

  group('G-Q2 密钥泄露扫描（DevSecOps §7.3 L1）', () {
    /// 取 git 跟踪的文件清单；非 git 环境返回 null（调用方据此判 SKIP 而非 PASS）。
    List<String>? trackedFiles() {
      final result = Process.runSync(
        'git',
        // -c core.quotePath=false：quotePath 默认开启，会把 CJK 文件名转义成
        // 八进制序列（如 说明文档.md → "\350\257\264..."），含中文名的文件
        // 将在扫描面中静默消失（评审 #4：125 个 CJK 路径文件曾漏扫）。
        ['-c', 'core.quotePath=false', 'ls-files'],
        workingDirectory: repoRoot.path,
        // 默认按系统编码解码（Windows 简体环境为 GBK），UTF-8 字节会解错；
        // git 输出恒为 UTF-8，必须显式指定。
        stdoutEncoding: utf8,
      );
      if (result.exitCode != 0) return null;
      return (result.stdout as String)
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    test('git 跟踪文件中无私钥 PEM 头 / 云 AK 形态串', () async {
      final files = trackedFiles();
      if (files == null) {
        // CI 上判不了必须红（评审 #11）：SKIP 在 CI 报告里与绿勾同形，
        // 等于静默放过整道门；仅本地非 git 环境允许记 SKIP。
        skipOrFailOnCi(
          ciFailReason: 'CI 环境 git ls-files 失败：密钥扫描面不可得，'
              '按四态诚实性记 FAIL 而非 SKIP（门禁在 CI 上必须可判定）。',
          localSkipReason: '非 git 环境（git ls-files 失败），密钥扫描面不可得——'
              '按门禁四态记 SKIP 而非 PASS：没扫过不等于干净。',
        );
        return;
      }

      // 扫描面自证（评审 #4）：CJK 文件名必须在列——quotePath 与解码任一环节
      // 出错都会让含中文名的文件静默消失，扫描面缩水不得报通过。
      expect(files, contains('说明文档.md'),
          reason: 'git ls-files 输出未包含 说明文档.md：文件名被转义或解码错误'
              '（core.quotePath 默认把 CJK 文件名转成八进制转义序列），'
              '扫描面静默缩水不得报通过。');

      final findings = <String>[]; // 未豁免的硬命中（强判据直接 FAIL）
      final exempted = <String>[]; // 已登记豁免的弱命中（列名留证，不静默）
      // 未能完整扫描的文件（fail-closed，复审 #1）：解码失败/疑似 UTF-16
      // 的文件实际脱离扫描面，WARN+PASS 等于把「没扫」报成「干净」——
      // 与上方「扫描面缩水不得报通过」同口径，此处必须 FAIL。
      final scanGaps = <String>[];

      // 强判据标记用变量插值拼装：源码行直接写相邻字面量 'A' 'B' 会被
      // 本文件的坍缩通道（评审 #5）还原命中强判据且不可豁免。
      const pemPrefix = 'PRIVATE KEY';
      final pemMarker = '$pemPrefix-----';

      /// 对一行（或其拼接候选）跑全部判据；[note] 标注候选来源通道。
      void checkLine(String rel, int lineNo, String text, String note) {
        final loc = '$rel:$lineNo$note';
        // 强判据：私钥 PEM 头 / 阿里云 AK 形态串——不给豁免通道，命中即 FAIL。
        if (text.contains(pemMarker)) {
          findings.add('$loc 私钥 PEM 头（强判据，不可豁免）');
        }
        if (RegExp(r'\bLTAI[A-Za-z0-9]{12,}\b').hasMatch(text)) {
          findings.add('$loc 疑似阿里云 AccessKey ID（强判据，不可豁免）');
        }
        // 弱判据：32 位 hex + 密钥语义上下文。命中后逐命中三分支处置
        // （复审 #4）：firstMatch 只判行内首个 hex——占位/登记串在前的
        // 同行真密钥会被掩蔽；处置粒度必须是「每个 hex 命中」而非「行」。
        if (looksLikeEmbeddedSecret(text)) {
          for (final match in hex32Pattern.allMatches(text)) {
            final hex = match.group(0)!;
            switch (classifySecretHex(rel, hex)) {
              case SecretHitVerdict.placeholder:
                continue; // 模板占位假值（aaaa.../cccc...），非真实密钥
              case SecretHitVerdict.exempted:
                exempted.add('$loc（已登记豁免）');
              case SecretHitVerdict.unregistered:
                findings.add(
                    '$loc 疑似密钥（32 位 hex + 密钥上下文，未登记豁免）：${text.trim()}');
            }
          }
        }
      }

      for (final rel in files) {
        if (isScanExcluded(rel)) continue;
        final f = repoFile(rel);
        if (!f.existsSync()) {
          // 已跟踪但工作区缺失（删除未提交/sparse 未展开）：该文件在 HEAD
          // 中仍可能携带密钥，静默 continue 即漏扫（复审三 #4，与解码失败
          // 同口径 fail-closed）——记入缺口迫使显式处置。
          scanGaps.add('$rel: git 已跟踪但工作区缺失（未提交删除或 sparse-checkout），'
              'HEAD 内容未扫描');
          continue;
        }
        // 流式逐行扫描（评审 #1）：原 512KB 上限把大文件整体静默跳扫——
        // prototype/index.html（>1MB）内未登记的高德 Key 因此漏网。
        // 取消体积上限，改逐行流式读，内存占用与文件大小解耦。
        String? prevLine;
        var lineNo = 0;
        var gapRecorded = false; // 每文件只记一次缺口，不刷屏
        try {
          await for (final line in f
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
            lineNo++;
            // UTF-16 特征检测（复审 #1）：0x00 是合法 UTF-8 不抛解码异常，
            // 但 hex32 与上下文词正则被 NUL 逐字符打断——该文件实际未受
            // 扫描且无 WARN，必须 fail-closed 记入缺口。
            if (!gapRecorded && line.contains('\x00')) {
              scanGaps.add('$rel: 行内含 NUL 字节（疑似 UTF-16/二进制，'
                  '扫描判据逐字符失声）');
              gapRecorded = true;
            }
            // 三通道（评审 #5）：原行 / 同行相邻字面量坍缩 / 跨行相邻拼接。
            checkLine(rel, lineNo, line, '');
            final collapsed = collapseAdjacentLiterals(line);
            if (collapsed != line) {
              checkLine(rel, lineNo, collapsed, '（同行拼接坍缩候选）');
            }
            final crossed = crossLineCandidate(prevLine, line);
            if (crossed != null) {
              checkLine(rel, lineNo, crossed, '（跨行拼接候选）');
            }
            prevLine = line;
          }
        } catch (e) {
          // 单文件读取/解码失败不得让整道门失声，但也绝不 WARN+PASS
          // （复审 #1）：该文件未完整扫描即脱离扫描面，必须 fail-closed。
          scanGaps.add('$rel: 读取或 UTF-8 解码失败（本文件未完整扫描）：$e');
        }
      }
      // 豁免列名打印——四态原则：豁免必须显式留证，不允许静默放过。
      if (exempted.isNotEmpty) {
        // ignore: avoid_print
        print('[INFO] 密钥扫描豁免命中 ${exempted.length} 处（登记册见 registeredSecretFindings，'
            '各条均须按 remediation 到云控制台作废更换）：\n  ${exempted.join('\n  ')}');
      }
      // fail-closed（复审 #1）：任何未完整扫描的文件都让本门 FAIL。
      // 合法二进制/UTF-16 资产的正确出口是在 isScanExcluded 显式登记排除
      // （评审可见），而不是 WARN 放过。
      expect(scanGaps, isEmpty,
          reason: '以下文件未能完整扫描（扫描面缩水不得报通过）：\n'
              '${scanGaps.join('\n')}\n'
              '若是合法二进制/UTF-16 资产，在 isScanExcluded 显式登记排除；'
              '若是文本文件，转为 UTF-8 编码。');
      expect(findings, isEmpty,
          reason: '跟踪文件中发现未豁免的疑似密钥（§7.3：命中即拒绝；'
              '已泄露的唯一处置是作废更换；正当例外须登记 registeredSecretFindings）：\n'
              '${findings.join('\n')}');
    });

    test('豁免登记册中每条都仍在仓库中存在（防过期凑数登记）', () {
      final stale = <String>[];
      for (final r in registeredSecretFindings) {
        final f = repoFile(r.file);
        if (!f.existsSync() ||
            !f.readAsLinesSync().any((l) => l.contains(r.lineContains))) {
          stale.add('${r.file}（${r.provider}）——代码已清理但豁免登记未移除；请删除该条目');
        }
      }
      expect(stale, isEmpty, reason: stale.join('\n'));
    });

    test('.gitignore 覆盖 .env 与签名密钥文件（§7.3 兜底）', () {
      final ignore = repoFile('.gitignore');
      expect(ignore.existsSync(), isTrue, reason: '.gitignore 缺失');
      final text = ignore.readAsStringSync();
      expect(text, contains('.env'), reason: '.gitignore 未覆盖 .env 文件');
      expect(text, contains('.jks'), reason: '.gitignore 未覆盖 Android 签名库 .jks');
      expect(text, contains('.keystore'), reason: '.gitignore 未覆盖 .keystore');
    });
  });

  // 判据自检：正向跑通不构成证据，必须证明判据对应当失败的输入真会失败（准则 9.9）。
  group('G-Q2 判据自检（变异防护：证明扫描器真有检出能力）', () {
    test('looksLikeEmbeddedSecret 对真实形态命中必须返回 true', () {
      // 样例密钥串一律插值拼装：源码行若写相邻字面量拆串，会被坍缩通道
      // （评审 #5）把本文件自身判为命中（自扫描防护）。
      expect(looksLikeEmbeddedSecret("    key: '$_gaodeSample',"), isTrue);
      expect(looksLikeEmbeddedSecret("apiKey: '$_skSample'"), isTrue);
      expect(looksLikeEmbeddedSecret('JWT_SECRET=$_hex16$_hex16'), isTrue);
      // 上下文大小写不敏感：KEY / Token 也须命中（32 个 a）
      expect(looksLikeEmbeddedSecret('MY_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), isTrue);
      // hex 大小写均命中：真实密钥不保证小写（评审 #10）
      expect(looksLikeEmbeddedSecret('amap key=$_upperHexSample'), isTrue);
    });

    test('looksLikeEmbeddedSecret 对合法噪声必须返回 false（防误杀）', () {
      expect(looksLikeEmbeddedSecret('final uuid = "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d";'), isFalse);
      expect(looksLikeEmbeddedSecret('// key: 这是注释里的 32 位 $_hex16$_hex16'), isFalse);
      expect(looksLikeEmbeddedSecret('# secret 注释 $_hex16$_hex16'), isFalse);
      expect(looksLikeEmbeddedSecret('const padding = "abcdefghijklmnopqrstuvwxyz012345";'), isFalse);
      expect(looksLikeEmbeddedSecret('normal text without secret context'), isFalse);
    });

    test('isRepeatedCharPlaceholder 精确识别模板占位（全同字符）', () {
      expect(isRepeatedCharPlaceholder('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'), isTrue);
      expect(isRepeatedCharPlaceholder('cccccccccccccccccccccccccccccccc'), isTrue);
      expect(isRepeatedCharPlaceholder(_gaodeSample), isFalse);
    });

    test('isRegisteredSecretHex 按文件+命中串精确匹配（防跨文件/同行冒名，复审 #4）', () {
      // 登记的泄露串本人在登记文件中 → 豁免
      expect(isRegisteredSecretHex('prototype/search.js', _skHex32), isTrue);
      // 同样的 key 出现在未登记文件不得豁免
      expect(isRegisteredSecretHex('lib/leaked.dart', _skHex32), isFalse);
      // 同行冒名（复审 #4）：同一已登记文件内的【新】32hex 不得连带豁免
      expect(isRegisteredSecretHex('prototype/search.js', _gaodeSample), isFalse);
    });

    test('classifySecretHex 逐命中三分支：占位+真密钥同行只跳占位（复审 #4）', () {
      // 占位假值 → placeholder（firstMatch 时代会 return 丢弃整行其余命中）
      expect(classifySecretHex('.env.example', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
          SecretHitVerdict.placeholder);
      // 登记串本人 → exempted
      expect(classifySecretHex('prototype/search.js', _skHex32),
          SecretHitVerdict.exempted);
      // 与登记串同行的真密钥 → unregistered（不得被登记位掩蔽）
      expect(classifySecretHex('prototype/search.js', _gaodeSample),
          SecretHitVerdict.unregistered);
      // 未登记文件的真密钥 → unregistered
      expect(classifySecretHex('lib/leaked.dart', _skHex32),
          SecretHitVerdict.unregistered);
    });

    test('collapseAdjacentLiterals 还原同行相邻字面量（评审 #5 检出通道）', () {
      // 用插值构造拆写形态，源码行自身不得含可坍缩还原的完整串。
      final splitForm = "    key: '${_gaodeSample.substring(0, 16)}' "
          "'${_gaodeSample.substring(16)}',";
      final collapsed = collapseAdjacentLiterals(splitForm);
      expect(collapsed, contains(_gaodeSample));
      expect(looksLikeEmbeddedSecret(collapsed), isTrue);
      // 无相邻字面量时原样返回
      expect(collapseAdjacentLiterals('normal line'), 'normal line');
    });

    test('collapseAdjacentLiterals 还原 `+` 显式拼接（复审 #3 文法放宽）', () {
      // 'a' + 'b' 加号拼接是最常见的拆写形态，原窄文法不匹配加号。
      final plusForm = "    key: '${_gaodeSample.substring(0, 16)}' + "
          "'${_gaodeSample.substring(16)}',";
      final collapsed = collapseAdjacentLiterals(plusForm);
      expect(collapsed, contains(_gaodeSample));
      expect(looksLikeEmbeddedSecret(collapsed), isTrue);
      // 混引号 + 加号
      final mixedForm = "    key: '${_gaodeSample.substring(0, 16)}' + "
          '"${_gaodeSample.substring(16)}",';
      expect(collapseAdjacentLiterals(mixedForm), contains(_gaodeSample));
    });

    test('crossLineCandidate 识别跨行相邻字面量（评审 #5 检出通道）', () {
      final prev = "    key: '${_gaodeSample.substring(0, 16)}'";
      final cur = "'${_gaodeSample.substring(16)}',";
      final crossed = crossLineCandidate(prev, cur);
      expect(crossed, isNotNull);
      expect(crossed, contains(_gaodeSample));
      expect(looksLikeEmbeddedSecret(crossed!), isTrue);
      // 非相邻引号边界返回 null
      expect(crossLineCandidate('normal line', 'another line'), isNull);
      expect(crossLineCandidate(null, 'first line'), isNull);
    });

    test('crossLineCandidate 识别混引号与 `+` 拼接跨行（复审 #3 文法放宽）', () {
      // 上双引号收尾、下单引号开头（Dart 合法相邻字面量）
      final mixed = crossLineCandidate(
          '    key: "${_gaodeSample.substring(0, 16)}"',
          "'${_gaodeSample.substring(16)}',");
      expect(mixed, isNotNull);
      expect(mixed, contains(_gaodeSample));
      // 行尾 + 拼接：'abc' +\n'def'
      final plusTail = crossLineCandidate(
          "    key: '${_gaodeSample.substring(0, 16)}' +",
          "'${_gaodeSample.substring(16)}',");
      expect(plusTail, isNotNull);
      expect(plusTail, contains(_gaodeSample));
      // 行首 + 拼接：'abc'\n+ 'def'
      final plusHead = crossLineCandidate(
          "    key: '${_gaodeSample.substring(0, 16)}'",
          "+ '${_gaodeSample.substring(16)}',");
      expect(plusHead, isNotNull);
      expect(plusHead, contains(_gaodeSample));
    });

    test('盲区固化：3 行拆分/块注释/行尾 // 注释不覆盖（复审 #3、复审三 #2）', () {
      // 负向自检把盲区固化为可见已知限制：若日后通道扩展到覆盖这些形态，
      // 本用例变红提醒同步更新函数注释的「已知盲区」登记。
      // 3 行拆分 11/11/10：任意两行候选凑不出 32 位连续 hex。
      final l1 = "    key: '${_gaodeSample.substring(0, 11)}'";
      final l2 = "'${_gaodeSample.substring(11, 22)}'";
      final l3 = "'${_gaodeSample.substring(22)}',";
      final pair12 = crossLineCandidate(l1, l2)!;
      final pair23 = crossLineCandidate(l2, l3)!;
      expect(pair12, isNot(contains(_gaodeSample)));
      expect(pair23, isNot(contains(_gaodeSample)));
      // 块注释夹隔：'a' /* x */ + 'b' 不还原。
      final commentForm = "    key: '${_gaodeSample.substring(0, 16)}' /* x */ + "
          "'${_gaodeSample.substring(16)}',";
      expect(collapseAdjacentLiterals(commentForm),
          isNot(contains(_gaodeSample)));
      // 行尾 // 行注释夹隔（复审三 #2）：词法上注释等价空白，仍是合法相邻
      // 字面量，但当前通道不还原——固化为可见盲区，含/不含行尾 + 两态。
      final lineCommentForm =
          crossLineCandidate("    key: '${_gaodeSample.substring(0, 16)}' // 注释",
              "'${_gaodeSample.substring(16)}',");
      expect(lineCommentForm, isNull);
      final lineCommentPlusForm = crossLineCandidate(
          "    key: '${_gaodeSample.substring(0, 16)}' // 注释 +",
          "'${_gaodeSample.substring(16)}',");
      expect(lineCommentPlusForm, isNull);
    });

    test('isCi 谓词覆盖平台写法差异（复审 #11 纯函数自检）', () {
      expect(isCi({'CI': 'true'}), isTrue);
      expect(isCi({'CI': 'TRUE'}), isTrue);
      expect(isCi({'CI': '1'}), isTrue);
      expect(isCi({'CI': 'yes'}), isTrue);
      expect(isCi({'CI': 'false'}), isFalse);
      expect(isCi({'CI': 'FALSE'}), isFalse);
      expect(isCi({'CI': ''}), isFalse);
      expect(isCi(const {}), isFalse);
    });
  });

  group('G-Q3 部署脚本 git 执行位（条目 [108] 实测缺陷）', () {
    test('deploy/scripts/*.sh 在 git 索引中为 100755', () {
      final result = Process.runSync(
        'git',
        ['ls-files', '-s', 'deploy/scripts/'],
        workingDirectory: repoRoot.path,
      );
      if (result.exitCode != 0) {
        // CI 上判不了必须红（评审 #11）：SKIP 在 CI 报告里与绿勾同形。
        skipOrFailOnCi(
          ciFailReason: 'CI 环境 git ls-files -s 失败：执行位扫描面不可得，'
              '记 FAIL 而非 SKIP。',
          localSkipReason: '非 git 环境，无法读取索引模式位——记 SKIP 而非 PASS。',
        );
        return;
      }
      final bad = <String>[];
      var seen = 0; // 实际纳入判定的 .sh 数量（评审 #7：空扫描面不得报通过）
      for (final line in (result.stdout as String).split('\n')) {
        if (line.trim().isEmpty) continue;
        // 格式：<mode> <hash> <stage>\t<path>
        final parts = line.split(RegExp(r'\s+'));
        final mode = parts.first;
        final path = line.split('\t').last;
        if (path.endsWith('.sh')) {
          seen++;
          if (mode != '100755') {
            bad.add('$path 当前模式 $mode');
          }
        }
      }
      expect(seen, greaterThan(0),
          reason: 'deploy/scripts/ 下未扫到任何 .sh 文件：扫描面为空时 PASS 是假阴性'
              '（与 assertRepoLayout 同一防护原则）。');
      expect(bad, isEmpty,
          reason: '以下部署脚本缺执行位（门禁脚本自己没有执行位，'
              '在 Linux/macOS 上 `bash x.sh` 之外的调用方式全部失败）：\n'
              '${bad.join('\n')}\n'
              '修复：git update-index --chmod=+x <file>（或 chmod +x 后 git add）');
    });
  });
}
