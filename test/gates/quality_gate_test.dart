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
  return p.contains('.pydeps/') ||
      p.contains('/.dart_tool/') ||
      p.contains('/build/') ||
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

/// 同行相邻字符串字面量坍缩：把 `'abc' 'def'` / `"abc" "def"` 形式的
/// 编译期拼接还原成单串，作为密钥扫描的附加候选行。
///
/// 背景（评审 #5，KTD6 绕过）：把 32 位 hex 拆成两段相邻字面量即可躲过
/// 逐行正则判据；坍缩通道让这种拆写在扫描视角下重新拼回完整串。
///
/// 参数：[line] 原始行文本。
/// 返回：`String` 坍缩后的候选行；无相邻字面量时与原行相等。
/// 注意：空字符串 `''` 也会被吃掉，故本函数产物只作附加扫描候选，
/// 原行仍是第一通道，两者互补。
String collapseAdjacentLiterals(String line) =>
    line.replaceAll(RegExp(r'''['"][ \t]*['"]'''), '');

/// 跨行相邻字面量候选：上行以引号收尾、下行以同种引号开头时，
/// 去掉边界引号拼接两行内容（覆盖 KTD6 的跨行拆写形态，评审 #5）。
///
/// 参数：[prevLine] 上一行原文（文件首行传 null）；[line] 当前行原文。
/// 返回：`String?` 可拼接时返回拼接候选，否则 null。
String? crossLineCandidate(String? prevLine, String line) {
  if (prevLine == null) return null;
  final prev = prevLine.trimRight();
  final cur = line.trimLeft();
  if (prev.isEmpty || cur.isEmpty) return null;
  final quote = prev[prev.length - 1];
  if ((quote == "'" || quote == '"') && cur.startsWith(quote)) {
    return '${prev.substring(0, prev.length - 1)}${cur.substring(1)}';
  }
  return null;
}

/// 判断某个「文件:行号:行内容」命中是否已在豁免登记册中。
///
/// 参数：[relPath] 相对仓库根的文件路径；[lineText] 命中行原文（已 trim 与否均可）。
/// 返回：`bool`，命中某条登记（文件且行内含定位子串）返回 true。
bool isRegisteredFinding(String relPath, String lineText) =>
    registeredSecretFindings
        .any((r) => r.file == relPath && lineText.contains(r.lineContains));

/// 判据自检样例串（统一承载，防各用例重复字面量）。
///
/// 变量命名刻意避开 key|secret|token|amap|高德|password|passwd 上下文词，
/// 使声明行自身不命中弱判据；使用处一律插值引用——源码行若直接写
/// 相邻字面量拆串，会被坍缩/跨行通道（评审 #5）把本文件自身判为命中。
const String _gaodeSample = 'aa6ff0d9da3a35cd35b8d192a00d1d85';
const String _skSample = 'sk-f2885e8725e04ec690db459cea8bcc57';
const String _hex16 = '0123456789abcdef';
const String _upperHexSample = '9C4AF3B304F2138FF4A7E55C470F69D3';

void main() {
  // 先断言仓库布局存在——扫描面为空时 PASS 是假阴性（gate-check G2/G9 同型缺陷）。
  setUpAll(assertRepoLayout);

  group('G-Q1 后门码 888888 登记册（DevSecOps §4.1 源码层）', () {
    /// 扫描 lib/ 下所有 .dart 文件，返回命中 888888 的 `文件:行号:行内容`。
    List<String> scanHits() {
      final hits = <String>[];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains('888888')) {
            final rel = entity.path
                .replaceAll('\\', '/')
                .split('/lib/')
                .last;
            hits.add('lib/$rel:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
      return hits;
    }

    test('lib/ 中每个 888888 字面量都在登记册中有对应条目', () {
      final hits = scanHits();
      final unregistered = <String>[];
      for (final hit in hits) {
        final file = hit.split(':').first;
        final matched = registeredBackdoors.any((b) {
          final lineText = hit.substring(hit.indexOf(': ') + 2);
          return b.file == file && lineText.contains(b.lineContains);
        });
        if (!matched) unregistered.add(hit);
      }
      expect(unregistered, isEmpty,
          reason: '发现未登记的 888888 后门码（DevSecOps §4.1：无法逐处确认即失败）：\n'
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
        if (Platform.environment['CI'] == 'true') {
          fail('CI 环境 git ls-files 失败：密钥扫描面不可得，'
              '按四态诚实性记 FAIL 而非 SKIP（门禁在 CI 上必须可判定）。');
        }
        // flutter_test 的跳过原语：标记本测试为 SKIP（对应门禁四态之 SKIP），
        // 而非静默 PASS——没扫过不等于干净。
        markTestSkipped('非 git 环境（git ls-files 失败），密钥扫描面不可得——'
            '按门禁四态记 SKIP 而非 PASS：没扫过不等于干净。');
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
        // 弱判据：32 位 hex + 密钥语义上下文。命中后三分支处置。
        if (looksLikeEmbeddedSecret(text)) {
          final hex = hex32Pattern.firstMatch(text)!.group(0)!;
          if (isRepeatedCharPlaceholder(hex)) {
            return; // 模板占位假值（aaaa.../cccc...），非真实密钥
          }
          if (isRegisteredFinding(rel, text)) {
            exempted.add('$loc（已登记豁免）');
          } else {
            findings.add(
                '$loc 疑似密钥（32 位 hex + 密钥上下文，未登记豁免）：${text.trim()}');
          }
        }
      }

      for (final rel in files) {
        if (isScanExcluded(rel)) continue;
        final f = repoFile(rel);
        if (!f.existsSync()) continue;
        // 流式逐行扫描（评审 #1）：原 512KB 上限把大文件整体静默跳扫——
        // prototype/index.html（>1MB）内未登记的高德 Key 因此漏网。
        // 取消体积上限，改逐行流式读，内存占用与文件大小解耦。
        String? prevLine;
        var lineNo = 0;
        try {
          await for (final line in f
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
            lineNo++;
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
          // 单文件读取/解码失败不得让整道门失声，但必须显式留证
          // （四态诚实性：不静默跳过）。
          // ignore: avoid_print
          print('[WARN] $rel 读取或 UTF-8 解码失败，本文件未完整扫描：$e');
        }
      }
      // 豁免列名打印——四态原则：豁免必须显式留证，不允许静默放过。
      if (exempted.isNotEmpty) {
        // ignore: avoid_print
        print('[INFO] 密钥扫描豁免命中 ${exempted.length} 处（登记册见 registeredSecretFindings，'
            '各条均须按 remediation 到云控制台作废更换）：\n  ${exempted.join('\n  ')}');
      }
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

    test('isRegisteredFinding 按文件+行内子串精确匹配（防跨文件冒名）', () {
      expect(isRegisteredFinding('prototype/search.js',
          "    API_KEY: '$_skSample', // 注释"), isTrue);
      // 同样的 key 出现在未登记文件不得豁免
      expect(isRegisteredFinding('lib/leaked.dart',
          "const k='$_skSample';"), isFalse);
      // 登记了别的文件但本行没有对应 key 串
      expect(isRegisteredFinding('prototype/search.js', 'API_KEY: placeholder'), isFalse);
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
        if (Platform.environment['CI'] == 'true') {
          fail('CI 环境 git ls-files -s 失败：执行位扫描面不可得，记 FAIL 而非 SKIP。');
        }
        markTestSkipped('非 git 环境，无法读取索引模式位——记 SKIP 而非 PASS。');
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
