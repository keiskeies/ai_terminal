import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/ui_text.dart';
import '../utils/line_diff.dart';
import '../utils/local_file_ops.dart';
import '../utils/tool_args_parser.dart';
import 'agent_tool.dart';
import 'command_executor.dart';
import 'local_file_policy.dart';
import '../core/l10n_holder.dart';

/// 本地文件工具集 — 读写**运行本 App 的这台机器**上的文件
///
/// 与远程工具的分工（写进 description，避免 AI 选错）：
/// - 服务器上的文件 → `file_write` / `file_patch`（走 SFTP 字节直传）
/// - 本机的文件 → `local_*`（Dart 文件 I/O，受 LocalFilePolicy 白名单约束）
///
/// 所有路径都要先过 [LocalFilePolicy.decide]：白名单 + 敏感黑名单 + 符号链接解析。
/// 判定不通过时不执行任何 I/O，直接把拒绝原因回给 AI。
abstract class LocalFileTool extends AgentTool {
  /// 授权根之外的额外目录（如本次任务里 project_analyze 记录的项目根）
  final List<String> Function()? extraRoots;

  /// 测试注入点；生产始终重新读取设置，不缓存授权快照。
  @visibleForTesting
  final LocalFilePolicy Function()? policyLoader;

  LocalFileTool({this.extraRoots, this.policyLoader});

  Future<String?> _freshDenial(String rawPath, String expectedResolved) async {
    final decision = _policy.verify(rawPath, expectedResolved,
        extraRoots: extraRoots?.call() ?? const []);
    return decision.isAllowed ? null : decision.reason ?? '路径授权状态已变化';
  }

  /// 本工具是否为写操作（决定拒绝信息里要不要提示关闭只读模式）
  bool get isWriteOperation => false;

  /// 解析并判定路径。返回 decision；被拒绝时返回一个失败 ToolResult。
  Future<Object> _resolve(String rawPath, LocalFilePolicy policy) async {
    final decision =
        policy.decide(rawPath, extraRoots: extraRoots?.call() ?? const []);
    if (!decision.isAllowed) {
      final prefix = switch (decision.verdict) {
        LocalPathVerdict.sensitive => '敏感路径禁止访问',
        LocalPathVerdict.reserved => '系统保留目录',
        LocalPathVerdict.notInAllowlist => '路径未获授权',
        LocalPathVerdict.escape => '路径跳出授权目录',
        LocalPathVerdict.allowed => '路径不可用',
      };
      return ToolResult.failure(
        '$prefix: $rawPath\n原因: ${decision.reason ?? '未通过白名单判定'}\n'
        '若确需访问，请让用户在 设置 → Agent → 本地文件 中添加该目录。'
        '${_remotePathHint(rawPath, decision.verdict)}',
      );
    }
    return decision;
  }

  /// 反向混淆提示：在 Windows 本机上传来一个 `/etc/...` 路径，多半是想改服务器
  ///
  /// 只在"未获授权"这一种判定下说：敏感/保留目录的拒绝本身是对的，
  /// 加一句"也许你想要的是远程工具"反而会引导 AI 绕过去。
  String _remotePathHint(String rawPath, LocalPathVerdict verdict) {
    if (verdict != LocalPathVerdict.notInAllowlist) return '';
    if (!Platform.isWindows || !looksLikePosixRemotePath(rawPath)) return '';
    return '\n注意: 这看起来是远程主机的路径，而 local_* 工具只改这台电脑。'
        '要改服务器文件请用 file_write / file_patch / sftp_upload。';
  }

  LocalFilePolicy get _policy =>
      policyLoader == null ? LocalFilePolicy.load() : policyLoader!();
}

/// 读取本机文件（带行号，便于 AI 后续用 local_file_patch 精确引用）
/// 参数:
///   - path: 文件绝对路径（必填）
///   - start_line: 起始行，从 1 开始（可选，默认 1）
///   - max_lines: 最多返回行数（可选，默认 400）
class LocalFileReadTool extends LocalFileTool {
  LocalFileReadTool({super.extraRoots});

  @override
  String get name => 'local_file_read';

  @override
  ToolKind get kind => ToolKind.read;

  @override
  String get description => '读取**本机**（运行 App 的这台机器）文本文件，按行号返回。'
      '要看服务器上的文件请用 cat/sed 走 SSH 命令，不要用本工具。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 本机文件绝对路径（必填）\n'
      '  start_line: 起始行，从 1 开始（可选，默认 1）\n'
      '  max_lines: 最多返回行数（可选，默认 400）';

  @override
  Map<String, dynamic>? toJsonSchema() => const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '本机文件绝对路径'},
          'start_line': {'type': 'integer', 'description': '起始行，从 1 开始'},
          'max_lines': {'type': 'integer', 'description': '最多返回行数'},
        },
        'required': ['path'],
      };

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final policy = _policy;
    final rawPath = args.getString('path');
    final resolved = await _resolve(rawPath, policy);
    if (resolved is ToolResult) return resolved;
    final path = (resolved as LocalPathDecision).resolved;

    final file = File(path);
    if (!await file.exists()) return ToolResult.failure('文件不存在: $path');
    if (_kindOf(path) == _PathKind.directory) {
      return ToolResult.failure('这是个目录，请用 local_dir_list: $path');
    }

    final size = await file.length();
    if (size > policy.maxReadBytes) {
      return ToolResult.failure(
        '文件过大（${(size / 1024 / 1024).toStringAsFixed(1)}MB，上限 '
        '${(policy.maxReadBytes / 1024 / 1024).toStringAsFixed(1)}MB）: $path\n'
        '本工具会整文件读入后再切片，start_line/max_lines 无法绕过大小上限。'
        '请用 local_file_search 定位内容，或用本地编辑器查看。',
      );
    }

    final beforeOpen = await file.stat();
    final String text;
    try {
      final handle = await file.open();
      try {
        // TOCTOU：判定路径到打开之间可能被换成符号链接/其它文件，
        // 打开后必须复核授权与路径身份，再读内容。
        final denial = await _freshDenial(rawPath, path);
        if (denial != null) {
          return ToolResult.failure('读取被拒绝: $path\n原因: $denial');
        }
        final afterOpen = await file.stat();
        if (!sameLocalFileIdentity(beforeOpen, afterOpen) ||
            await handle.length() != afterOpen.size) {
          return ToolResult.failure('文件在打开后发生变化，已中止读取: $path');
        }
        final bytes = await handle.read(policy.maxReadBytes + 1);
        if (bytes.length > policy.maxReadBytes) {
          return ToolResult.failure('文件在读取期间超过大小上限，已中止读取: $path');
        }
        text = utf8.decode(bytes);
      } finally {
        await handle.close();
      }
    } catch (e) {
      return ToolResult.failure('读取失败（可能无权限、文件已删除或不是 UTF-8）: $path\n$e');
    }

    final lines = const LineSplitter().convert(text);
    final startLine = args
        .getInt('start_line', defaultValue: 1)
        .clamp(1, lines.isEmpty ? 1 : lines.length);
    final maxLines = args.getInt('max_lines', defaultValue: 400).clamp(1, 5000);
    final end = startLine - 1 + maxLines > lines.length
        ? lines.length
        : startLine - 1 + maxLines;

    // R8: 行数与字节上限都不足以约束输出（2MB 文件可以只有几行超长行），
    // 再按「单行字符 + 整段字符」两级截断，避免把整份文件塞进模型上下文。
    var written = 0;
    var lastLine = startLine - 1;
    final buffer = StringBuffer();
    for (var i = startLine - 1; i < end; i++) {
      var line = lines[i];
      if (line.length > SftpFileReadTool.maxLineChars) {
        line =
            '${line.substring(0, SftpFileReadTool.maxLineChars)}…(行过长，截断 ${line.length - SftpFileReadTool.maxLineChars} 字符)';
      }
      final entry = '${i + 1}\t$line\n';
      // 首行永远收录（单行上限小于总上限）
      if (written + entry.length > SftpFileReadTool.maxSliceChars &&
          buffer.isNotEmpty) {
        break;
      }
      buffer.write(entry);
      written += entry.length;
      lastLine = i + 1;
    }
    final header = '文件: $path（共 ${lines.length} 行，显示 $startLine-$lastLine）';
    final tail = lastLine < lines.length
        ? '\n...还有 ${lines.length - lastLine} 行，用 start_line: ${lastLine + 1} 继续'
        : '';
    return ToolResult.success('$header\n$buffer$tail');
  }
}

/// 列目录
/// 参数:
///   - path: 目录绝对路径（必填）
///   - depth: 递归层数（可选，默认 1，最大 3）
///   - glob: 只保留匹配的文件名模式，逗号分隔（可选，如 *.dart,*.yaml）
class LocalDirListTool extends LocalFileTool {
  LocalDirListTool({super.extraRoots});

  @override
  String get name => 'local_dir_list';

  @override
  ToolKind get kind => ToolKind.read;

  @override
  String get description => '列出**本机**目录内容（文件带大小，目录带 / 后缀）。'
      '默认跳过 .git / node_modules / build 等噪音目录。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 本机目录绝对路径（必填）\n'
      '  depth: 递归层数（可选，默认 1，最大 3）\n'
      '  glob: 只保留匹配的文件名，逗号分隔，如 *.dart,*.yaml（可选）\n'
      '  include_hidden: 是否包含隐藏文件（可选，默认 false）';

  static const _skippedDirs = {
    '.git',
    'node_modules',
    'build',
    'dist',
    '.dart_tool',
    '__pycache__',
    'target'
  };

  @override
  Map<String, dynamic>? toJsonSchema() => const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'depth': {'type': 'integer', 'description': '递归层数，1-3'},
          'glob': {'type': 'string', 'description': '逗号分隔的文件名模式'},
          'include_hidden': {'type': 'boolean'},
        },
        'required': ['path'],
      };

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final rawPath = args.getString('path');
    final resolved = await _resolve(rawPath, _policy);
    if (resolved is ToolResult) return resolved;
    final path = (resolved as LocalPathDecision).resolved;

    final dir = Directory(path);
    if (!await dir.exists()) return ToolResult.failure('目录不存在: $path');

    final depth = args.getInt('depth', defaultValue: 1).clamp(1, 3);
    final includeHidden = args.getBool('include_hidden');
    final patterns = args
        .getStringList('glob')
        .map(_globToRegExp)
        .whereType<RegExp>()
        .toList();

    final buffer = StringBuffer('目录: $path（depth=$depth）\n');
    var entries = 0;
    var skipped = 0;
    const maxEntries = 800;

    Future<void> walkLocalDir(Directory d, String prefix, int level) async {
      if (level > depth || entries >= maxEntries) return;
      final children = <FileSystemEntity>[];
      try {
        await for (final e in d.list(followLinks: false)) {
          children.add(e);
        }
      } catch (e) {
        buffer.writeln('$prefix(无法读取: $e)');
        return;
      }
      children.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return p.basename(a.path).compareTo(p.basename(b.path));
      });

      for (final child in children) {
        if (entries >= maxEntries) {
          buffer.writeln('$prefix... 条目过多，已截断（用更深的过滤条件缩小范围）');
          return;
        }
        final base = p.basename(child.path);
        final isDir = child is Directory;
        // 先查"明确跳过的构建/依赖目录"，再查隐藏文件：
        // 顺序反了的话 .git 会被当成普通隐藏目录静默隐藏，AI 会以为这个目录是空的
        if (isDir && _skippedDirs.contains(base)) {
          skipped++;
          buffer.writeln('$prefix$base/  (已跳过)');
          continue;
        }
        if (!includeHidden && base.startsWith('.')) {
          skipped++;
          continue;
        }
        if (!isDir &&
            patterns.isNotEmpty &&
            !patterns.any((r) => r.hasMatch(base))) {
          skipped++;
          continue;
        }
        String sizeInfo = '';
        if (!isDir) {
          try {
            sizeInfo = '  ${_humanSize(await child.stat())}';
          } catch (_) {}
        }
        buffer.writeln('$prefix$base${isDir ? "/" : ""}$sizeInfo');
        entries++;
        if (isDir && level < depth) {
          await walkLocalDir(child, '$prefix  ', level + 1);
        }
      }
    }

    await walkLocalDir(dir, '', 1);

    final out = buffer.toString();
    if (entries == 0) {
      return ToolResult.success('$out\n（该目录下没有匹配的条目，跳过 $skipped 个）');
    }
    return ToolResult.success(
        '$out\n共 $entries 个条目${skipped > 0 ? "，跳过 $skipped 个" : ""}');
  }

  static RegExp? _globToRegExp(String glob) {
    if (glob.trim().isEmpty) return null;
    final escaped = RegExp.escape(glob.trim())
        .replaceAll(r'\*', '.*')
        .replaceAll(r'\?', '.');
    return RegExp('^$escaped\$', caseSensitive: !Platform.isWindows);
  }

  static String _humanSize(FileStat stat) {
    final b = stat.size;
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}K';
    return '${(b / 1024 / 1024).toStringAsFixed(1)}M';
  }
}

/// 在本机目录里搜文件内容（Dart 侧遍历，不走 shell）
/// 参数:
///   - path: 文件或目录绝对路径（必填）
///   - query: 要搜索的文本（必填）
///   - glob: 文件名过滤，逗号分隔（可选）
///   - ignore_case: 忽略大小写（可选，默认 false）
///   - max_matches: 最多返回命中数（可选，默认 100）
class LocalFileSearchTool extends LocalFileTool {
  LocalFileSearchTool({super.extraRoots, super.policyLoader});

  @override
  String get name => 'local_file_search';

  @override
  ToolKind get kind => ToolKind.read;

  @override
  String get description => '在**本机**文件或目录里按内容搜索，返回 path:line: 内容。'
      '用 Dart 遍历实现，跨平台且不受 shell/locale 影响（服务器上请仍用远程 grep）。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 本机文件或目录绝对路径（必填）\n'
      '  query: 要搜索的文本（必填，按字面量匹配）\n'
      '  glob: 文件名过滤，逗号分隔，如 *.dart（可选）\n'
      '  ignore_case: 忽略大小写（可选，默认 false）\n'
      '  max_matches: 最多返回命中行数（可选，默认 100）';

  @override
  Map<String, dynamic>? toJsonSchema() => const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'query': {'type': 'string'},
          'glob': {'type': 'string'},
          'ignore_case': {'type': 'boolean'},
          'max_matches': {'type': 'integer'},
        },
        'required': ['path', 'query'],
      };

  static const _skippedDirs = {
    '.git',
    'node_modules',
    'build',
    'dist',
    '.dart_tool',
    '__pycache__',
    'target'
  };

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final rawPath = args.getString('path');
    final query = args.getString('query');
    if (query.isEmpty) {
      return ToolResult.failure(
          UiText.t('参数缺失: query 必填', 'Missing parameter: query is required'));
    }

    final resolved = await _resolve(rawPath, _policy);
    if (resolved is ToolResult) return resolved;
    final path = (resolved as LocalPathDecision).resolved;

    final ignoreCase = args.getBool('ignore_case');
    final maxMatches =
        args.getInt('max_matches', defaultValue: 100).clamp(1, 1000);
    final needle = ignoreCase ? query.toLowerCase() : query;
    final patterns = args.getStringList('glob').map((g) {
      final escaped = RegExp.escape(g.trim())
          .replaceAll(r'\*', '.*')
          .replaceAll(r'\?', '.');
      return RegExp('^$escaped\$', caseSensitive: !Platform.isWindows);
    }).toList();

    final files = <String>[];
    var walkCapped = false;
    final entity = _kindOf(path);
    if (entity == _PathKind.missing) {
      return ToolResult.failure('路径不存在: $path');
    }
    if (entity == _PathKind.file) {
      files.add(path);
    } else {
      await for (final c
          in Directory(path).list(recursive: true, followLinks: false)) {
        if (c is! File) continue;
        // 完整路径只拆一次，再在 Set 上做 O(1) 命中判断。
        // 原来对每个跳过目录都重新 split 一次完整路径（7 目录约 7×）。
        final segments = p.split(c.path);
        if (segments.any(_skippedDirs.contains)) continue;
        if (patterns.isNotEmpty &&
            !patterns.any((r) => r.hasMatch(p.basename(c.path)))) {
          continue;
        }
        files.add(c.path);
        if (files.length >= 5000) {
          // R8：截断必须说出来。不报的话，AI 会把"扫了 5000 个文件没找到"
          // 当成"整个目录里没有"，然后给出一个错误的结论。
          walkCapped = true;
          break;
        }
      }
    }

    final hits = <String>[];
    final denied = <String>[];
    final oversized = <String>[];
    final changed = <String>[];
    var scanned = 0;
    // 项目根等额外授权必须参与逐文件复判：漏掉它时 project_analyze 根下
    // 的每个文件都会被判为未授权，最终误报“扫描 0 个文件、未命中”。
    final roots = extraRoots?.call() ?? const <String>[];
    for (final f in files) {
      if (hits.length >= maxMatches) break;
      // 根目录授权不能继承给后代：每个文件在打开前重新判定，且打开后再判定一次。
      // 不做循环外预判，避免同一文件重复跑三次策略判定。
      final didScan = await _scanFileLines(
        file: f,
        needle: needle,
        ignoreCase: ignoreCase,
        hits: hits,
        maxMatches: maxMatches,
        root: path,
        authorize: () async {
          final current = _policy.decide(f, extraRoots: roots);
          return current.isAllowed ? null : current.reason ?? '路径授权状态已变化';
        },
        onDenied: denied.add,
        onOversize: oversized.add,
        onChanged: changed.add,
      );
      if (!didScan) continue;
      scanned++;
      if (scanned % 200 == 0) {
        onProgress?.call(L10n.str.ut_b5e97db76b(scanned));
      }
    }

    final walkNote = walkCapped
        ? UiText.t('\n注意: 文件数已达 5000 上限，未继续遍历，请用 glob 或更窄的 path 缩小范围',
            '\nNote: reached the 5000-file cap and stopped walking; narrow the scope with glob or a tighter path')
        : '';
    final deniedNote = denied.isEmpty
        ? ''
        : '\n已跳过 ${denied.length} 个未获授权/敏感文件: '
            '${denied.take(20).join(', ')}${denied.length > 20 ? ' …' : ''}';
    final oversizedNote = oversized.isEmpty
        ? ''
        : '\n已跳过 ${oversized.length} 个超过 2MB 的文件（未搜索）: '
            '${oversized.take(10).join(', ')}${oversized.length > 10 ? ' …' : ''}';
    // 身份变化是“扫描期间文件被换掉”的并发信号，不是用户未授权；分开报告，
    // 否则 AI 会把并发写文件误判成权限配置问题，反复去调授权。
    final changedNote = changed.isEmpty
        ? ''
        : '\n已跳过 ${changed.length} 个在扫描期间发生变化的文件（结果不可信）: '
            '${changed.take(10).join(', ')}${changed.length > 10 ? ' …' : ''}';
    if (hits.isEmpty) {
      return ToolResult.success(
          '未命中。搜索 "$query"，实际扫描 $scanned 个文件（发现 ${files.length} 个，$path）$deniedNote$oversizedNote$changedNote$walkNote');
    }
    final more =
        hits.length >= maxMatches ? '\n...已达 $maxMatches 条上限，用 glob 缩小范围' : '';
    return ToolResult.success(
        '${hits.length} 处命中（扫描 $scanned 个文件）\n${hits.join('\n')}$deniedNote$oversizedNote$changedNote$more$walkNote');
  }

  String _rel(String file, String root) {
    if (_kindOf(root) == _PathKind.file) return file;
    final rel = p.relative(file, from: root);
    return rel;
  }

  Future<bool> _scanFileLines({
    required String file,
    required String needle,
    required bool ignoreCase,
    required List<String> hits,
    required int maxMatches,
    required String root,
    required Future<String?> Function() authorize,
    required void Function(String) onDenied,
    required void Function(String) onOversize,
    required void Function(String) onChanged,
  }) async {
    RandomAccessFile? handle;
    try {
      var denial = await authorize();
      if (denial != null) {
        onDenied(file);
        return false;
      }
      final target = File(file);
      final before = await target.stat();
      if (before.size > 2 * 1024 * 1024) {
        // 超大/二进制：跳过并显式报告，不能计为"已扫描"。
        onOversize(file);
        return false;
      }
      handle = await target.open(mode: FileMode.read);
      denial = await authorize();
      if (denial != null) {
        onDenied(file);
        return false;
      }
      final after = await target.stat();
      if (before.size != after.size ||
          before.modified != after.modified ||
          before.mode != after.mode ||
          before.type != after.type ||
          await handle.length() != after.size) {
        onChanged(file); // 打开期间身份变化，fail-closed。
        return false;
      }
      var lineNo = 0;
      Stream<Uint8List> chunks() async* {
        while (true) {
          final chunk = await handle!.read(64 * 1024);
          if (chunk.isEmpty) break;
          yield chunk;
        }
      }

      await for (final line in const Utf8Decoder(allowMalformed: true)
          .bind(chunks())
          .transform(const LineSplitter())) {
        lineNo++;
        final haystack = ignoreCase ? line.toLowerCase() : line;
        if (!haystack.contains(needle)) continue;
        final text = line.length > 200 ? '${line.substring(0, 200)}…' : line;
        hits.add('${_rel(file, root)}:$lineNo: $text');
        if (hits.length >= maxMatches) break;
      }
      return true;
    } catch (_) {
      // 无权限/非 UTF-8/读取失败：跳过该文件，不把部分结果冒充完整搜索。
      return false;
    } finally {
      await handle?.close();
    }
  }
}

/// 写/追加本机文件
/// 参数:
///   - path: 本机文件绝对路径（必填）
///   - content: 文本内容，换行写成 \n（与 content_b64 二选一）
///   - content_b64: base64 内容（二进制或需逐字节保真时用）
///   - mode: write | append（可选，默认 write）
///   - backup: 覆盖前是否备份（可选，默认 true）
class LocalFileWriteTool extends LocalFileTool {
  LocalFileWriteTool({super.extraRoots, super.policyLoader});

  @override
  String get name => 'local_file_write';

  @override
  bool get isWriteOperation => true;

  @override
  String get description => '写入或追加**本机**文件（Dart 直接 I/O，绕过 shell 转义）。'
      '覆盖已有文件前自动备份为 .bak.{时间戳}，写失败自动回滚。'
      '要写服务器上的文件请用 file_write。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 本机文件绝对路径（必填）\n'
      '  content: 文本内容，换行用 \\n 表示（与 content_b64 二选一）\n'
      '  content_b64: base64 内容，二进制或需逐字节保真时用\n'
      '  mode: write | append（可选，默认 write）\n'
      '  backup: 覆盖前是否备份（可选，默认 true）\n'
      '注意：单块 content 原文不超过 8KB；更大的文件分多次 mode=append。';

  @override
  Map<String, dynamic>? toJsonSchema() => const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'content': {'type': 'string'},
          'content_b64': {'type': 'string'},
          'mode': {
            'type': 'string',
            'enum': ['write', 'append']
          },
          'backup': {'type': 'boolean'},
        },
        'required': ['path'],
      };

  static const int _maxChunkBytes = 8 * 1024;

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final rawPath = args.getString('path');
    final mode = args.getString('mode', defaultValue: 'write');
    if (mode != 'write' && mode != 'append') {
      return ToolResult.failure(L10n.str.ut_132456dcfb(mode));
    }
    final resolved = await _resolve(rawPath, _policy);
    if (resolved is ToolResult) return resolved;
    final path = (resolved as LocalPathDecision).resolved;

    final contentB64 = args.getString('content_b64');
    final plainContent = args.getString('content');
    if (contentB64.length > ((_maxChunkBytes + 2) ~/ 3) * 4) {
      return ToolResult.failure('content_b64 编码内容过大，已中止解码。');
    }
    if (contentB64.isEmpty && plainContent.length > _maxChunkBytes) {
      return ToolResult.failure('content 原文长度超过 ${_maxChunkBytes}B 上限，已中止转义解码。'
          '请分块写入：第一次 mode=write 写前 8KB，之后用 mode=append 续写。');
    }
    final content = decodeContent(
      plain: contentB64.isEmpty ? decodeEscapedText(plainContent) : '',
      b64: contentB64,
    );
    if (content.isFailed) return ToolResult.failure(content.error!);
    if (content.bytes.isEmpty &&
        mode == 'write' &&
        contentB64.isEmpty &&
        plainContent.isEmpty) {
      // 显式空 content 也是危险操作：write 会把文件截断成 0 字节还报成功。
      // append 空内容是无副作用的 no-op，不拦。
      return ToolResult.failure(UiText.t(
          'content 或 content_b64 不能为空：write 模式会清空文件。'
              '多行内容请写在同一行并用 \\n 表示换行。',
          'content or content_b64 must not be empty: write truncates the file. '
              'Write multi-line content on a single line using \\n for newlines.'));
    }
    if (content.bytes.length > _maxChunkBytes) {
      return ToolResult.failure(
        '单块内容 ${content.bytes.length} 字节，超过 ${_maxChunkBytes}B 上限。\n'
        '请分块：第一次 mode=write 写前 8KB，之后用 mode=append 续写。',
      );
    }

    final outcome = await writeLocalFile(
      path: path,
      bytes: content.bytes,
      append: mode == 'append',
      backup: args.getBool('backup', defaultValue: true),
      authorizePath: _freshDenial,
      authorizeOpenedWrite: (_) => _freshDenial(rawPath, path),
    );
    if (!outcome.success) return ToolResult.failure(outcome.error ?? '写入失败');
    return ToolResult.success(
      '本机文件${mode == 'append' ? '追加' : '写入'}成功: $path（${outcome.bytesWritten} 字节）'
      '${outcome.backupPath != null ? '\n原文件已备份: ${outcome.backupPath}' : ''}',
      restoreFrom: outcome.backupPath,
      restoreTo: outcome.backupPath == null ? null : path,
    );
  }
}

/// 字符串替换式修改本机文件
class LocalFilePatchTool extends LocalFileTool {
  LocalFilePatchTool({super.extraRoots, super.policyLoader});

  @override
  String get name => 'local_file_patch';

  @override
  bool get isWriteOperation => true;

  @override
  String get description => '改**本机**文件的少量内容：只提供 old/new，工具做字符串替换。'
      'old 必须在文件中唯一出现，否则报错要你给更长上下文。写前会校验文件未被外部改动。'
      '要改服务器上的文件请用 file_patch。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 本机文件绝对路径（必填）\n'
      '  old: 被替换的原文（与 old_b64 二选一）\n'
      '  new: 替换后的内容（与 new_b64 二选一；删除内容时留空）\n'
      '  old_b64 / new_b64: 多行或含特殊字符时改用 base64\n'
      '  backup: 是否备份（可选，默认 true）';

  @override
  Map<String, dynamic>? toJsonSchema() => const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'old': {'type': 'string'},
          'new': {'type': 'string'},
          'old_b64': {'type': 'string'},
          'new_b64': {'type': 'string'},
          'backup': {'type': 'boolean'},
        },
        'required': ['path'],
      };

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final rawPath = args.getString('path');
    final policy = _policy;
    final resolved = await _resolve(rawPath, policy);
    if (resolved is ToolResult) return resolved;
    final path = (resolved as LocalPathDecision).resolved;

    final oldPlainRaw = args.getString('old');
    final newPlainRaw = args.getString('new');
    final oldB64 = args.getString('old_b64');
    final newB64 = args.getString('new_b64');
    const maxPatchArgBytes = 64 * 1024;
    const maxEncodedPatchArg = ((maxPatchArgBytes + 2) ~/ 3) * 4;
    if (oldB64.length > maxEncodedPatchArg ||
        newB64.length > maxEncodedPatchArg) {
      return ToolResult.failure('old_b64/new_b64 编码内容过大，已中止解码。');
    }
    if ((oldB64.isEmpty && oldPlainRaw.length > maxPatchArgBytes) ||
        (newB64.isEmpty && newPlainRaw.length > maxPatchArgBytes)) {
      return ToolResult.failure('old/new 原文长度超过 64KB 上限，已中止转义解码。');
    }
    final oldPlain = oldB64.isEmpty ? decodeEscapedText(oldPlainRaw) : '';
    final newPlain = newB64.isEmpty ? decodeEscapedText(newPlainRaw) : '';

    final oldDecoded = decodeContent(plain: oldPlain, b64: oldB64);
    final newDecoded = decodeContent(plain: newPlain, b64: newB64);
    if (oldDecoded.isFailed) return ToolResult.failure(oldDecoded.error!);
    if (newDecoded.isFailed) return ToolResult.failure(newDecoded.error!);

    if (oldPlain.isEmpty && oldB64.isEmpty) {
      return ToolResult.failure('参数缺失: old 或 old_b64 必须提供');
    }
    if (oldDecoded.bytes.length > maxPatchArgBytes ||
        newDecoded.bytes.length > maxPatchArgBytes) {
      return ToolResult.failure('old/new 解码内容超过 64KB 上限，已中止修改。');
    }

    // 用字节级补丁：old_b64/new_b64 可能是任意二进制/非 UTF-8，
    // 先解码成 String 再 utf8 重编码会改写 BOM 之外的原始字节。
    final outcome = await patchLocalFileBytes(
      path: path,
      oldBytes: oldDecoded.bytes,
      newBytes: newDecoded.bytes,
      backup: args.getBool('backup', defaultValue: true),
      maxBytes: policy.maxReadBytes,
      authorizePath: _freshDenial,
      authorizeOpenedWrite: (handle) async {
        final current = _policy;
        if (await handle.length() > current.maxReadBytes) {
          return '文件大小已超过当前策略读取上限 ${current.maxReadBytes} 字节';
        }
        return _freshDenial(rawPath, path);
      },
      oldText: utf8Decode(oldDecoded.bytes),
      newText: utf8Decode(newDecoded.bytes),
    );
    if (!outcome.success) return ToolResult.failure(outcome.error ?? '替换失败');

    final diff = LineDiff.compute(outcome.oldText ?? '', outcome.newText ?? '');
    final diffText =
        diff == null ? '' : '（+${diff.additions} -${diff.deletions} 行）';
    return ToolResult(
      success: true,
      output: '本机文件已修改: $path$diffText'
          '${outcome.backupPath != null ? '\n原文件已备份: ${outcome.backupPath}' : ''}',
      diffAdditions: diff?.additions,
      diffDeletions: diff?.deletions,
      restoreFrom: outcome.backupPath,
      restoreTo: outcome.backupPath == null ? null : path,
    );
  }

  static String utf8Decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }
}

/// 移动/重命名本机文件
class LocalFileMoveTool extends LocalFileTool {
  LocalFileMoveTool({super.extraRoots});

  @override
  String get name => 'local_file_move';

  @override
  bool get isWriteOperation => true;

  @override
  String get description => '移动或重命名**本机**文件/目录。源和目标都必须在授权目录内。'
      '默认不覆盖已存在的目标。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 源文件绝对路径（必填）\n'
      '  dst: 目标绝对路径（必填）\n'
      '  overwrite: 目标已存在时是否覆盖（可选，默认 false）';

  @override
  Map<String, dynamic>? toJsonSchema() => const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'dst': {'type': 'string'},
          'overwrite': {'type': 'boolean'},
        },
        'required': ['path', 'dst'],
      };

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final src = await _resolve(args.getString('path'), _policy);
    if (src is ToolResult) return src;
    final dst = await _resolve(args.getString('dst'), _policy);
    if (dst is ToolResult) return dst;
    final srcPath = (src as LocalPathDecision).resolved;
    final dstPath = (dst as LocalPathDecision).resolved;

    final type = _kindOf(srcPath);
    if (type == _PathKind.missing) {
      return ToolResult.failure('源不存在: $srcPath');
    }
    final exists = _kindOf(dstPath) != _PathKind.missing;
    if (exists && !args.getBool('overwrite')) {
      return ToolResult.failure('目标已存在: $dstPath\n确认要覆盖请传 overwrite: true。');
    }
    if (exists) {
      try {
        await _deleteRecursively(dstPath);
      } catch (e) {
        return ToolResult.failure('无法清理目标: $e');
      }
    }

    try {
      // 目标父目录可能还不存在；先建出来，rename 才能成功
      await Directory(p.dirname(dstPath)).create(recursive: true);
      if (type == _PathKind.directory) {
        await Directory(srcPath).rename(dstPath);
      } else {
        await File(srcPath).rename(dstPath);
      }
    } catch (e) {
      // rename 跨盘会失败；退化成 copy + delete
      try {
        if (type == _PathKind.directory) {
          await _copyDirectory(Directory(srcPath), Directory(dstPath));
          await Directory(srcPath).delete(recursive: true);
        } else {
          await File(srcPath).copy(dstPath);
          await File(srcPath).delete();
        }
        return ToolResult.success(
          '本机移动成功（跨盘，已用复制+删除）: $srcPath -> $dstPath',
          restoreFrom: dstPath,
          restoreTo: srcPath,
        );
      } catch (e2) {
        return ToolResult.failure('移动失败: $e\n退化复制也失败: $e2');
      }
    }
    return ToolResult.success(
      '本机移动成功: $srcPath -> $dstPath',
      restoreFrom: dstPath,
      restoreTo: srcPath,
    );
  }
}

/// 删除本机文件（默认移入回收目录）
class LocalFileDeleteTool extends LocalFileTool {
  LocalFileDeleteTool({super.extraRoots});

  @override
  String get name => 'local_file_delete';

  @override
  ToolKind get kind => ToolKind.destructive;

  @override
  bool get isWriteOperation => true;

  @override
  String get description => '删除**本机**文件/目录。默认不真删：移入授权目录下的 '
      '.ai_terminal_trash/ 回收区，可从台账还原。需要真删时用户会显式传 hard: true。';

  @override
  String get paramSpec => '参数列表（多行 key:value 格式）：\n'
      '  path: 要删除的本机路径（必填）\n'
      '  recursive: 目录是否递归删除（可选，默认 false）\n'
      '  hard: true 则真删不可恢复（可选，默认 false —— 移入回收区）';

  @override
  Map<String, dynamic>? toJsonSchema() => const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'recursive': {'type': 'boolean'},
          'hard': {'type': 'boolean'},
        },
        'required': ['path'],
      };

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final resolved = await _resolve(args.getString('path'), _policy);
    if (resolved is ToolResult) return resolved;
    final path = (resolved as LocalPathDecision).resolved;

    final type = _kindOf(path);
    if (type == _PathKind.missing) {
      return ToolResult.failure('路径不存在: $path');
    }
    final isDir = type == _PathKind.directory;
    final recursive = args.getBool('recursive');
    if (isDir && !recursive) {
      return ToolResult.failure('$path 是目录。确认要连内容一起删除请传 recursive: true。');
    }

    if (args.getBool('hard')) {
      try {
        await _deleteRecursively(path);
        return ToolResult.success('已永久删除: $path');
      } catch (e) {
        return ToolResult.failure('删除失败: $e');
      }
    }

    // 移入回收区：保留相对结构，便于还原时放回原位。
    // 回收区目录名由 LocalFilePolicy 统一定义并列为保留目录 —— 工具自身走
    // rename 写入不经过策略判定，但 AI 用其它 local_* 工具碰它会被拒。
    final trashRoot = p.join(p.dirname(path), LocalFilePolicy.trashDirName);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final target = p.join(trashRoot, '$stamp', p.basename(path));
    try {
      await Directory(p.join(trashRoot, '$stamp')).create(recursive: true);
      if (isDir) {
        await Directory(path).rename(target);
      } else {
        await File(path).rename(target);
      }
    } catch (e) {
      return ToolResult.failure(
        '移入回收区失败: $e\n'
        '确认要跳过回收区直接删除时，请让用户同意后用 hard: true 重试。',
      );
    }
    return ToolResult.success(
      '已移入回收区（未真删，可还原）: $path\n回收位置: $target',
      restoreFrom: target,
      restoreTo: path,
    );
  }
}

/// 路径类型（跟随符号链接）
enum _PathKind { missing, file, directory }

_PathKind _kindOf(String path) {
  if (FileSystemEntity.isDirectorySync(path)) return _PathKind.directory;
  if (FileSystemEntity.isFileSync(path)) return _PathKind.file;
  return _PathKind.missing;
}

Future<void> _deleteRecursively(String path) async {
  final type = _kindOf(path);
  if (type == _PathKind.directory) {
    await Directory(path).delete(recursive: true);
  } else if (type != _PathKind.missing) {
    await File(path).delete();
  }
}

Future<void> _copyDirectory(Directory src, Directory dst) async {
  await dst.create(recursive: true);
  await for (final e in src.list(recursive: false, followLinks: false)) {
    final target = p.join(dst.path, p.basename(e.path));
    if (e is Directory) {
      await _copyDirectory(e, Directory(target));
    } else if (e is File) {
      await e.copy(target);
    }
  }
}

/// 注册本地文件工具到注册表
///
/// 单独成函数是因为它们需要 [extraRoots] 提供者（项目根），而其它工具不需要。
void registerLocalFileTools(
  AgentToolRegistry registry, {
  List<String> Function()? extraRoots,
}) {
  registry.register(LocalFileReadTool(extraRoots: extraRoots));
  registry.register(LocalDirListTool(extraRoots: extraRoots));
  registry.register(LocalFileSearchTool(extraRoots: extraRoots));
  registry.register(LocalFileWriteTool(extraRoots: extraRoots));
  registry.register(LocalFilePatchTool(extraRoots: extraRoots));
  registry.register(LocalFileMoveTool(extraRoots: extraRoots));
  registry.register(LocalFileDeleteTool(extraRoots: extraRoots));
}
