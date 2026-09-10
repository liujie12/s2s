/// 反冗余静态扫描守门测试：编码规范 §1.3 的机器可判前端判据。
///
/// 依据：详设 §14.2（`RetryInterceptor` 是全局唯一重试点，features 禁 `for` 循环重试）、
///       详设 §10.3（枚举一律 `switch` 显式映射，禁 `values.byName`）、
///       编码规范 §1.3（反冗余验收口径：两处静态扫描零命中）。
///
/// 两道判据的机器口径（唯一权威定义，与用例双向锁定）：
///
///   判据 A（features 循环重试，详设 §14.2）：
///     在词法剥离后的 `lib/features/` 代码上定位每个 `for`/`while` 语句，
///     循环头圆括号配对后提取循环体（`{...}` 块；无花括号时取至下一个 `;`
///     的单语句），循环体文本命中网络调用形态正则
///     `\.(get|post|patch|put|delete|fetch)\s*\(` 即判违规。
///     为什么是这个口径（§14.2「不出现 retry 相关循环」的保守机器化）：
///     - features 域唯一需要在循环体内发网络请求的形态就是重试/重放——
///       正常批量请求走 forEach / Future.wait 或单发，不写 for 循环；
///     - 普通 for 循环（集合变换、字符串拼装）循环体无网络调用形态，天然不命中；
///     - do-while 的循环体在 `while` 关键字之前，本判据提取到的是空语句，
///       永不误报（代价：do-while 重试是已知漏报面，存量为零，漏报向由
///       for/while 变异用例兜底）。
///
///   判据 B（`values.byName`，详设 §10.3）：
///     同一份词法剥离文本上，正则 `\bvalues\.byName\b` 零命中。
///     `byName` 在服务端新增枚举值时抛异常，必须显式 `switch` + `default` 降级。
///
///   词法剥离口径（两判据共用 [stripDartTrivia]）：
///     输出与输入等长。`//` 行注释与 `/* */` 块注释（含嵌套）替换为空格——
///     注释中出现 `values.byName`、`dio.get(` 等字样不算违规；
///     字符串静态文本（单/双/三引号、raw 串）替换为空格——字符串内容不参与判定；
///     字符串插值 `${...}` 内部代码保留（`$`/`{`/`}` 本身掏空，花括号配对关系不变），
///     插值是真实执行代码，其中的 `values.byName` 必须被检出；
///     换行符一律保留——行号与原文一一对应，违规定位精确到行。
///
///   判据对象缺失按 FAIL 处理（不是 SKIP）：
///     两个扫描函数对不存在的目录抛 [StateError]（《部署架构设计文档》§14.5
///     「先断言待判对象存在，再执行判据」，与 [assertRepoLayout] 同款防线）。
///     门禁四态中 SKIP 只留给「环境判不了」（如非 git 环境的 G-Q2/G-Q3），
///     判据对象整体缺失是门禁失效，必须红。
///
/// CI 消费链：本文件落 `test/gates/` 即被守门步 `flutter test test/gates/`
/// 消费（.github/workflows/ci.yml「守门测试」步消费整个目录，与契约守门、
/// G-Q1/G-Q2/G-Q3 并列），全量步 `flutter test` 再次消费；FAIL 则作业变红挡合并。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/repo_paths.dart';

/// 循环头正则（判据 A）：`for (`/`while (`。
///
/// 词边界防误命中：`forEach(`（`for` 后非 `(`）、`meanwhile(`（`while` 前是
/// 单词字符）均不匹配；do-while 的 `while (cond);` 会匹配，但其循环体在
/// 关键字之前，提取到的是空语句，永不误报（见文件头判据口径）。
final RegExp _loopHeadPattern = RegExp(r'\b(?:for|while)\s*\(');

/// 网络调用形态正则（判据 A 循环体命中条件）：带点方法调用形态的 HTTP 动词。
///
/// 为什么只抓带点形态：dio 的全部请求入口是方法调用（`dio.get(...)`），
/// 裸 `fetch(` 会误报普通函数名——保守不误报优先，漏报向由变异用例兜底。
/// `.getString(` 等更长的方法名不匹配（`get` 后须紧跟 `(`）。
final RegExp _networkCallPattern =
    RegExp(r'\.(get|post|patch|put|delete|fetch)\s*\(');

/// `values.byName` 正则（判据 B）：词边界防 `xvalues.byName` / `values.byNameX` 误命中。
final RegExp _valuesByNamePattern = RegExp(r'\bvalues\.byName\b');

/// 一条反冗余违规命中（含定位信息，toString 直接用于 expect 的 reason 输出）。
class AntiRedundancyViolation {
  /// 构造一条违规命中。
  const AntiRedundancyViolation({
    required this.ruleId,
    required this.file,
    required this.line,
    required this.lineText,
  });

  /// 判据标识：features 循环重试（详设 §14.2）。
  static const String ruleLoopRetry = 'features-loop-retry';

  /// 判据标识：禁 values.byName（详设 §10.3）。
  static const String ruleValuesByName = 'no-values-byname';

  /// 命中的判据标识（[ruleLoopRetry] / [ruleValuesByName]）。
  final String ruleId;

  /// 相对扫描根的 `/` 分隔路径（如 `discovery/listing_repository.dart`）。
  final String file;

  /// 命中行号（1 起，与原文一致——[stripDartTrivia] 保留全部换行）。
  final int line;

  /// 命中行原文（trim 后，便于人工定位确认）。
  final String lineText;

  @override
  String toString() => '$file:$line: [$ruleId] $lineText';
}

/// 词法帧种类：[stripDartTrivia] 状态机的栈帧类型。
enum _LexKind { code, lineComment, blockComment, string }

/// 词法栈帧：记录当前所处的注释/字符串/插值上下文。
class _LexFrame {
  /// 代码帧：[isInterpolation] 为 true 表示 `${ ... }` 插值内部代码，
  /// 其 depth 归零处的 `}` 是插值终结符（掏空）而非代码花括号（保留）。
  _LexFrame.code({this.isInterpolation = false})
      : kind = _LexKind.code,
        quote = '',
        triple = false,
        raw = false,
        depth = 0;

  /// 行注释帧（`//` 至换行终结）。
  _LexFrame.lineComment()
      : kind = _LexKind.lineComment,
        quote = '',
        triple = false,
        raw = false,
        isInterpolation = false,
        depth = 0;

  /// 块注释帧（`/* */`，Dart 允许嵌套，depth 从 1 起逐层计数）。
  _LexFrame.blockComment()
      : kind = _LexKind.blockComment,
        quote = '',
        triple = false,
        raw = false,
        isInterpolation = false,
        depth = 1;

  /// 字符串帧：[quote] 为引号字符（`'`/`"`），[triple] 为三引号标记，
  /// [raw] 为 raw 串标记（无转义、无插值）。
  _LexFrame.string(
      {required this.quote, required this.triple, required this.raw})
      : kind = _LexKind.string,
        isInterpolation = false,
        depth = 0;

  /// 帧种类。
  final _LexKind kind;

  /// 字符串引号字符（仅 string 帧使用）。
  final String quote;

  /// 是否三引号字符串（仅 string 帧使用）。
  final bool triple;

  /// 是否 raw 字符串（仅 string 帧使用）。
  final bool raw;

  /// 是否 `${...}` 插值代码帧（仅 code 帧使用）。
  final bool isInterpolation;

  /// 嵌套深度：块注释的 `/*` 嵌套层数，或代码帧内未配对的 `{` 数。
  int depth;
}

/// 剥离 Dart 源码中的注释与字符串静态文本，供两判据在同一份「干净代码」上匹配。
///
/// 功能：输出与输入等长的字符串——行注释、块注释（含嵌套）、字符串静态文本
/// （单/双/三引号、raw 串）逐字符替换为空格；字符串插值 `${...}` 的内部代码
/// 保留（`$`/`{`/`}` 边界本身掏空，花括号配对关系不变）；换行符一律保留，
/// 故输出中的偏移与行号与原文一一对应。
///
/// 为什么剥离后再匹配（详设 §10.3/§14.2 的机器化前提）：注释里讨论
/// `values.byName` 或「for 循环重试」字样是合法的文档行为，不构成违规；
/// 字符串静态文本同理。插值是真实执行代码，保留参与判定。
///
/// 参数：[source] 待剥离的 Dart 源码全文。
/// 返回：[String] 与输入等长的剥离结果（注释/字符串静态文本为空格，其余原样）。
String stripDartTrivia(String source) {
  final n = source.length;
  final out = List<String>.generate(n, (i) => source[i]);
  final stack = <_LexFrame>[_LexFrame.code()];

  /// 将位置 [j] 的字符掏空为空格（换行符保留，维持行号对应关系）。
  void blank(int j) {
    if (source[j] != '\n') out[j] = ' ';
  }

  /// 判断字符是否可作 Dart 标识符组成部分（用于 raw 串 `r` 前缀的边界判定）。
  bool isIdentifierChar(int j) {
    final u = source.codeUnitAt(j);
    return (u >= 0x41 && u <= 0x5A) || // A-Z
        (u >= 0x61 && u <= 0x7A) || // a-z
        (u >= 0x30 && u <= 0x39) || // 0-9
        u == 0x5F || // _
        u == 0x24; // $
  }

  var i = 0;
  while (i < n) {
    final c = source[i];
    final top = stack.last;
    switch (top.kind) {
      case _LexKind.lineComment:
        // 行注释：整体掏空，遇换行终结（换行本身保留）。
        if (c == '\n') {
          stack.removeLast();
        } else {
          blank(i);
        }
        i++;
      case _LexKind.blockComment:
        // 块注释：整体掏空，`/*`/`*/` 成对计数（Dart 允许嵌套块注释）。
        if (c == '/' && i + 1 < n && source[i + 1] == '*') {
          top.depth++;
          blank(i);
          blank(i + 1);
          i += 2;
        } else if (c == '*' && i + 1 < n && source[i + 1] == '/') {
          blank(i);
          blank(i + 1);
          i += 2;
          top.depth--;
          if (top.depth == 0) stack.removeLast();
        } else {
          blank(i);
          i++;
        }
      case _LexKind.string:
        // 字符串：静态文本掏空；非 raw 串处理 `\` 转义与 `${` 插值入口。
        if (!top.raw && c == '\\' && i + 1 < n) {
          blank(i);
          blank(i + 1);
          i += 2;
        } else if (!top.raw && c == '\$' && i + 1 < n && source[i + 1] == '{') {
          blank(i);
          blank(i + 1);
          i += 2;
          stack.add(_LexFrame.code(isInterpolation: true));
        } else if (c == top.quote) {
          if (top.triple) {
            // 三引号串内单个引号不终结字符串，须三连引号。
            if (i + 2 < n && source[i + 1] == c && source[i + 2] == c) {
              blank(i);
              blank(i + 1);
              blank(i + 2);
              i += 3;
              stack.removeLast();
            } else {
              blank(i);
              i++;
            }
          } else {
            blank(i);
            i++;
            stack.removeLast();
          }
        } else {
          blank(i);
          i++;
        }
      case _LexKind.code:
        if (c == '/' && i + 1 < n && source[i + 1] == '/') {
          blank(i);
          blank(i + 1);
          i += 2;
          stack.add(_LexFrame.lineComment());
        } else if (c == '/' && i + 1 < n && source[i + 1] == '*') {
          blank(i);
          blank(i + 1);
          i += 2;
          stack.add(_LexFrame.blockComment());
        } else if (c == "'" || c == '"') {
          // raw 前缀判定：紧邻引号前的 `r` 且其前非标识符字符
          // （防把标识符结尾的 r 误判为 raw 前缀）。
          final raw = i > 0 &&
              source[i - 1] == 'r' &&
              (i < 2 || !isIdentifierChar(i - 2));
          final triple = i + 2 < n && source[i + 1] == c && source[i + 2] == c;
          blank(i);
          if (triple) {
            blank(i + 1);
            blank(i + 2);
            i += 3;
          } else {
            i++;
          }
          stack.add(_LexFrame.string(quote: c, triple: triple, raw: raw));
        } else if (c == '{') {
          top.depth++;
          i++;
        } else if (c == '}') {
          if (top.isInterpolation && top.depth == 0) {
            // 插值终结符：随插值边界一并掏空，不参与外层花括号配对。
            blank(i);
            stack.removeLast();
          } else {
            top.depth--;
          }
          i++;
        } else {
          i++;
        }
    }
  }
  return out.join();
}

/// 断言判据扫描根存在。
///
/// 功能：判据对象缺失按 FAIL 处理（《部署架构设计文档》§14.5「先断言待判
/// 对象存在，再执行判据」，与 [assertRepoLayout] 同款防线）——扫描面为空
/// 给出的 PASS 是假阴性；SKIP 只留给「环境判不了」，不留给「对象没了」。
///
/// 参数：[scanRoot] 待扫描目录。
/// 返回：void；目录不存在时抛出 [StateError]。
void _assertScanRootExists(Directory scanRoot) {
  if (!scanRoot.existsSync()) {
    throw StateError(
      '判据扫描目录不存在：${scanRoot.path}'
      '（判据对象缺失按 FAIL 处理而非 SKIP，部署 §14.5）',
    );
  }
}

/// 收集扫描根下全部 `.dart` 文件（递归，按路径排序保证输出顺序稳定）。
///
/// 参数：[scanRoot] 扫描根目录（调用前必须已经 [_assertScanRootExists] 断言存在）。
/// 返回：[List<File>] 排序后的 Dart 文件清单。
List<File> _dartFilesUnder(Directory scanRoot) {
  final files = scanRoot
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// 计算文件相对扫描根的 `/` 分隔路径（违规定位用，跨平台输出一致）。
///
/// 参数：[file] 命中文件；[scanRoot] 扫描根目录。
/// 返回：[String] 如 `discovery/listing_repository.dart`；无法相对化时退化为全路径。
String _relativeSlashPath(File file, Directory scanRoot) {
  var rel = file.path;
  final rootPath = scanRoot.path;
  if (rel.startsWith(rootPath)) {
    rel = rel.substring(rootPath.length);
    while (rel.startsWith(Platform.pathSeparator)) {
      rel = rel.substring(Platform.pathSeparator.length);
    }
  }
  return rel.replaceAll('\\', '/');
}

/// 计算偏移量所在的行号（1 起）。
///
/// 参数：[text] 文本全文；[offset] 字符偏移量。
/// 返回：[int] 行号（逐字符数换行，命中路径才调用，频次极低）。
int _lineNumberAt(String text, int offset) {
  var line = 1;
  for (var i = 0; i < offset; i++) {
    if (text[i] == '\n') line++;
  }
  return line;
}

/// 取偏移量所在行的原文（trim 后）。
///
/// 参数：[source] 源码原文（非剥离文本，保证输出可读）；[offset] 字符偏移量。
/// 返回：[String] 命中行原文。
String _lineTextAt(String source, int offset) {
  var start = offset;
  while (start > 0 && source[start - 1] != '\n') {
    start--;
  }
  var end = offset;
  while (end < source.length && source[end] != '\n') {
    end++;
  }
  return source.substring(start, end).trim();
}

/// 括号配对：从 [openIndex] 的开括号出发找配对闭括号位置。
///
/// 在 [stripDartTrivia] 输出上运行——字符串静态文本与注释已掏空、插值边界
/// 已掏空且内部代码花括号保持平衡，故裸花括号/圆括号配对可信。
///
/// 参数：[text] 剥离后的文本；[openIndex] 开括号偏移；[open]/[close] 括号字符。
/// 返回：[int?] 配对闭括号偏移；畸形文本（配对耗尽文件尾）返回 null。
int? _matchBracket(String text, int openIndex, String open, String close) {
  var depth = 0;
  for (var i = openIndex; i < text.length; i++) {
    if (text[i] == open) {
      depth++;
    } else if (text[i] == close) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}

/// 跳过空白（含换行），定位循环体起点。
///
/// 参数：[text] 剥离后的文本；[from] 起始偏移。
/// 返回：[int] 首个非空白字符偏移（可能越界，调用方判界）。
int _skipWhitespace(String text, int from) {
  var i = from;
  while (i < text.length) {
    final c = text[i];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
    } else {
      break;
    }
  }
  return i;
}

/// 判据 A：扫描目录下 Dart 代码中的 for/while 循环重试（详设 §14.2）。
///
/// 功能：逐文件经 [stripDartTrivia] 剥离后定位每个 `for`/`while` 语句，
/// 圆括号配对循环头后提取循环体（`{...}` 块；无花括号时取至下一个 `;` 的
/// 单语句），循环体文本命中 [_networkCallPattern] 即记违规。同一行被嵌套
/// 循环重复圈中时按 (文件, 行) 去重只报一次。
///
/// 参数：[scanRoot] 扫描根目录（守护断言传 `lib/features/`，变异测试传
///   临时 fixtures 目录）；目录不存在抛 [StateError]（FAIL 而非 SKIP）。
/// 返回：[List<AntiRedundancyViolation>] 违规清单，空清单即 PASS。
List<AntiRedundancyViolation> scanLoopRetryViolations(Directory scanRoot) {
  _assertScanRootExists(scanRoot);
  final violations = <AntiRedundancyViolation>[];
  for (final file in _dartFilesUnder(scanRoot)) {
    final source = file.readAsStringSync();
    final stripped = stripDartTrivia(source);
    final relPath = _relativeSlashPath(file, scanRoot);
    final reportedLines = <int>{};
    for (final head in _loopHeadPattern.allMatches(stripped)) {
      // 循环头：正则以 `(` 收尾，配对找 `)`。
      final closeParen = _matchBracket(stripped, head.end - 1, '(', ')');
      if (closeParen == null) continue; // 畸形文本，保守跳过不误报
      final bodyStart = _skipWhitespace(stripped, closeParen + 1);
      if (bodyStart >= stripped.length) continue;
      // 循环体区间：花括号块取配对闭括号；单语句取至下一个 `;`。
      final int bodyEnd;
      if (stripped[bodyStart] == '{') {
        final closeBrace = _matchBracket(stripped, bodyStart, '{', '}');
        if (closeBrace == null) continue;
        bodyEnd = closeBrace;
      } else {
        final semicolon = stripped.indexOf(';', bodyStart);
        bodyEnd = semicolon == -1 ? stripped.length : semicolon;
      }
      final hit =
          _networkCallPattern.firstMatch(stripped.substring(bodyStart, bodyEnd));
      if (hit == null) continue;
      final offset = bodyStart + hit.start;
      final line = _lineNumberAt(stripped, offset);
      if (!reportedLines.add(line)) continue; // 嵌套循环圈中的同一行只报一次
      violations.add(AntiRedundancyViolation(
        ruleId: AntiRedundancyViolation.ruleLoopRetry,
        file: relPath,
        line: line,
        lineText: _lineTextAt(source, offset),
      ));
    }
  }
  return violations;
}

/// 判据 B：扫描目录下 Dart 代码中的 `values.byName`（详设 §10.3）。
///
/// 功能：逐文件经 [stripDartTrivia] 剥离后匹配 [_valuesByNamePattern]——
/// 注释与字符串静态文本中的字样不命中，插值表达式中的真实调用必须命中。
///
/// 参数：[scanRoot] 扫描根目录（守护断言传 `lib/`，变异测试传临时
///   fixtures 目录）；目录不存在抛 [StateError]（FAIL 而非 SKIP）。
/// 返回：[List<AntiRedundancyViolation>] 违规清单，空清单即 PASS。
List<AntiRedundancyViolation> scanValuesByNameViolations(Directory scanRoot) {
  _assertScanRootExists(scanRoot);
  final violations = <AntiRedundancyViolation>[];
  for (final file in _dartFilesUnder(scanRoot)) {
    final source = file.readAsStringSync();
    final stripped = stripDartTrivia(source);
    final relPath = _relativeSlashPath(file, scanRoot);
    for (final m in _valuesByNamePattern.allMatches(stripped)) {
      violations.add(AntiRedundancyViolation(
        ruleId: AntiRedundancyViolation.ruleValuesByName,
        file: relPath,
        line: _lineNumberAt(stripped, m.start),
        lineText: _lineTextAt(source, m.start),
      ));
    }
  }
  return violations;
}

/// features 域源码目录：`lib/features/`（判据 A 的扫描根）。
///
/// 派生自 [libDir] 而非独立常量，保持与 repo_paths 单一真源。
final Directory featuresDir =
    Directory('${libDir.path}${Platform.pathSeparator}features');

void main() {
  // 先断言待判对象存在，再执行判据（部署 §14.5 固定句式）：
  // 扫描面为空给出的 PASS 是假阴性，与 gate-check.sh G2/G9 同型缺陷。
  setUpAll(() {
    assertRepoLayout();
    if (!featuresDir.existsSync()) {
      throw StateError(
        'lib/features/ 目录缺失，判据 A（循环重试扫描）失去判定对象——'
        '按 FAIL 处理而非 SKIP（部署 §14.5：先断言待判对象存在，再执行判据）。',
      );
    }
  });

  group('守护断言：真实 lib/ 零命中（编码规范 §1.3）', () {
    test('lib/features/ 无 for/while 循环重试（详设 §14.2）', () {
      final violations = scanLoopRetryViolations(featuresDir);
      expect(violations, isEmpty,
          reason: 'features 域发现循环重试（详设 §14.2：RetryInterceptor 是全局唯一重试点，'
              'repository 内禁止 for 循环重试）：\n'
              '${violations.join('\n')}\n'
              '修复：删除循环重试，网络失败交给 RetryInterceptor 统一退避。');
    });

    test('lib/ 无 values.byName（详设 §10.3）', () {
      final violations = scanValuesByNameViolations(libDir);
      expect(violations, isEmpty,
          reason: 'lib/ 发现 values.byName（详设 §10.3：枚举一律 switch 显式映射，'
              '服务端新增枚举值时 byName 会抛异常，switch 的 default 分支才能降级）：\n'
              '${violations.join('\n')}\n'
              '修复：改为显式 switch 映射 + default 降级。');
    });
  });

  group('变异自检（漏报向）：注入违规形态必 FAIL', () {
    test('for 循环体含网络调用注入 → 判据 FAIL，删除后恢复 PASS', () {
      final tmp = Directory.systemTemp.createTempSync('anti_redundancy_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final fixture =
          File('${tmp.path}${Platform.pathSeparator}retry_fixture.dart')
        ..writeAsStringSync('''
Future<void> load() async {
  for (var attempt = 0; attempt < 3; attempt++) {
    await dio.get('/posts');
  }
}
''');
      final hits = scanLoopRetryViolations(tmp);
      expect(hits, isNotEmpty, reason: '注入 for 循环重试必须被检出（漏报向）');
      expect(hits.single.file, 'retry_fixture.dart');
      expect(hits.single.line, 3,
          reason: '违规定位须精确到网络调用所在行（dart 多行字符串起始换行不计入内容，'
              'fixture 第 3 行即 await dio.get 行）');

      fixture.deleteSync();
      expect(scanLoopRetryViolations(tmp), isEmpty,
          reason: '删除违规文件后判据必须恢复 PASS');
    });

    test('while 循环体含网络调用注入 → 判据 FAIL', () {
      final tmp = Directory.systemTemp.createTempSync('anti_redundancy_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      File('${tmp.path}${Platform.pathSeparator}while_retry_fixture.dart')
          .writeAsStringSync('''
Future<void> load() async {
  var done = false;
  while (!done) {
    final resp = await dio.post('/posts', data: {});
    done = resp != null;
  }
}
''');
      final hits = scanLoopRetryViolations(tmp);
      expect(hits, isNotEmpty, reason: 'while 重试循环必须被检出');
      expect(hits.single.line, 4,
          reason: '网络调用在 while 循环体内（fixture 第 4 行即 dio.post 行）');
    });

    test('无花括号单语句 for 重试注入 → 判据 FAIL', () {
      final tmp = Directory.systemTemp.createTempSync('anti_redundancy_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      File('${tmp.path}${Platform.pathSeparator}single_stmt_fixture.dart')
          .writeAsStringSync('''
Future<void> load() async {
  for (var i = 0; i < 2; i++)
    await dio.patch('/posts/1/status', data: {});
}
''');
      expect(scanLoopRetryViolations(tmp), isNotEmpty,
          reason: '无花括号的单语句循环体同样是重试形态，必须被检出');
    });

    test('values.byName 注入 → 判据 FAIL 且定位精确', () {
      final tmp = Directory.systemTemp.createTempSync('anti_redundancy_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      File('${tmp.path}${Platform.pathSeparator}byname_fixture.dart')
          .writeAsStringSync('''
SupplyDemand parse(String raw) {
  return SupplyDemand.values.byName(raw);
}
''');
      final hits = scanValuesByNameViolations(tmp);
      expect(hits, isNotEmpty, reason: 'values.byName 注入必须被检出（漏报向）');
      expect(hits.single.file, 'byname_fixture.dart');
      expect(hits.single.line, 2, reason: 'byName 调用在 return 行（fixture 第 2 行）');
    });

    test('字符串静态文本不报、插值中的 values.byName 必报', () {
      final tmp = Directory.systemTemp.createTempSync('anti_redundancy_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      File('${tmp.path}${Platform.pathSeparator}interp_fixture.dart')
          .writeAsStringSync('''
String describe(String raw) {
  const hint = '禁用 values.byName，也禁止 dio.get 循环重试';
  return 'parsed: \${SupplyDemand.values.byName(raw)}, hint: \$hint';
}
''');
      final byNameHits = scanValuesByNameViolations(tmp);
      expect(byNameHits, hasLength(1),
          reason: '静态文本中的 values.byName 字样不命中；'
              '插值 \${...} 是真实执行代码，其中的一处必须被检出');
      expect(byNameHits.single.line, 3, reason: '命中行须是插值所在行（fixture 第 3 行 return 行）');
      expect(scanLoopRetryViolations(tmp), isEmpty,
          reason: '静态文本中的 dio.get 字样不构成循环重试');
    });
  });

  group('变异自检（误报向）：合法输入不误报', () {
    test('含 UUID v4 字面量与注释行的合法文件 → 两判据均不命中', () {
      final tmp = Directory.systemTemp.createTempSync('anti_redundancy_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      File('${tmp.path}${Platform.pathSeparator}clean_fixture.dart')
          .writeAsStringSync('''
/// 幂等键形态：3f6b2a90-8c1d-4e7a-9b2c-5d8e0f1a2b3c（UUID v4）。
/// 禁止 values.byName 映射枚举——本注释提及该字样不构成违规。
// 也禁止在 for 循环里写 dio.get('/x') 重试——本行注释同样不构成违规。
/* 块注释里的 values.byName 与 dio.post('/y') 字样也不构成违规。 */
const idempotencyKeyExample = '3f6b2a90-8c1d-4e7a-9b2c-5d8e0f1a2b3c';

String describe(int code) {
  switch (code) {
    case 0:
      return 'ok';
    default:
      return 'unknown';
  }
}
''');
      expect(scanValuesByNameViolations(tmp), isEmpty,
          reason: '注释行中的 values.byName 字样不得误报（判据剥离注释后再匹配）');
      expect(scanLoopRetryViolations(tmp), isEmpty,
          reason: '注释行中的循环网络调用字样不得误报');
    });

    test('合法普通 for 循环（无网络调用）→ 判据 A 不命中', () {
      final tmp = Directory.systemTemp.createTempSync('anti_redundancy_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      File('${tmp.path}${Platform.pathSeparator}plain_for_fixture.dart')
          .writeAsStringSync('''
List<String> namesOf(List<int> ids) {
  final names = <String>[];
  for (final id in ids) {
    names.add('item-\$id');
  }
  final buffer = StringBuffer();
  for (var i = 0; i < names.length; i++) {
    buffer.write(names[i]);
  }
  return names;
}
''');
      expect(scanLoopRetryViolations(tmp), isEmpty,
          reason: '普通 for 循环（add/write 等集合操作）循环体无网络调用形态，不得误报');
    });
  });

  group('判据对象缺失按 FAIL 处理（非 SKIP）', () {
    test('扫描目录不存在 → 两判据均抛 StateError', () {
      final missing =
          Directory('${Directory.systemTemp.path}${Platform.pathSeparator}'
              'anti_redundancy_missing_${DateTime.now().microsecondsSinceEpoch}');
      expect(missing.existsSync(), isFalse);
      expect(() => scanLoopRetryViolations(missing), throwsStateError,
          reason: '判据对象缺失是门禁失效，必须红而不是静默 SKIP');
      expect(() => scanValuesByNameViolations(missing), throwsStateError);
    });
  });

  group('stripDartTrivia 词法剥离单元行为', () {
    test('行注释与块注释（含嵌套）剥离为空格，换行保留使行号不变', () {
      const source = 'a // values.byName\n'
          'b /* nested /* inner */ tail */ c\n'
          'd';
      final stripped = stripDartTrivia(source);
      expect(stripped, isNot(contains('values.byName')));
      expect(stripped, isNot(contains('inner')));
      expect('\n'.allMatches(stripped).length, 2, reason: '换行保留，行号与原文一致');
      expect(stripped.length, source.length, reason: '输出与输入等长，偏移即原文偏移');
      expect(stripped.contains('c'), isTrue, reason: '块注释终结后的代码保留');
    });

    test('字符串静态文本掏空、插值代码保留、花括号配对不被字符串破坏', () {
      const source = "final s = 'a { values.byName } \$x \${f(y)}';\n"
          'final t = "tail";\n';
      final stripped = stripDartTrivia(source);
      expect(stripped, isNot(contains('values.byName')),
          reason: '静态文本中的字样掏空，不参与判定');
      expect(stripped, isNot(contains("'a")));
      expect(stripped.contains('f(y)'), isTrue, reason: '插值表达式是真实代码，保留');
      // 字符串内的 `{` 已掏空：剩余花括号只有插值的一对且已随插值掏空，
      // 不残留任何裸花括号破坏外层配对。
      expect(stripped.contains('{'), isFalse);
      expect(stripped.contains('}'), isFalse);
    });

    test('raw 字符串与三引号字符串（跨行）掏空', () {
      const source = """const r = r'raw values.byName';
const m = '''line1
line2 values.byName''';
const z = 1;""";
      final stripped = stripDartTrivia(source);
      expect(stripped, isNot(contains('values.byName')),
          reason: 'raw 串与三引号串的静态文本同样掏空');
      expect(stripped, isNot(contains('line1')));
      expect(stripped, isNot(contains('line2')));
      expect('\n'.allMatches(stripped).length, 3, reason: '三引号串内换行保留');
      expect(stripped.contains('const z'), isTrue, reason: '三引号串结束后的代码保留');
    });
  });
}
