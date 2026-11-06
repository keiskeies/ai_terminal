import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../utils/line_diff.dart';
import '../utils/local_file_ops.dart';
import '../utils/tool_args_parser.dart';
import 'agent_tool.dart';
import 'command_executor.dart';
import 'local_file_policy.dart';

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

  LocalFileTool({this.extraRoots});

  /// 本工具是否为写操作（决定拒绝信息里要不要提示关闭只读模式）
  bool get isWriteOperation => false;

  /// 解析并判定路径。返回 decision；被拒绝时返回一个失败 ToolResult。
  Future<Object> _resolve(String rawPath, LocalFilePolicy policy) async {
    final decision = policy.decide(rawPath, extraRoots: extraRoots?.call() ?? const []);
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

  LocalFilePolicy get _policy => LocalFilePolicy.load();
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
        '请用 start_line/max_lines 分段读，或直接用本地编辑器查看。',
      );
    }

    final String text;
    try {
      text = await file.readAsString();
    } catch (e) {
      return ToolResult.failure('读取失败（可能是二进制文件或不是 UTF-8）: $path\n$e');
    }

    final lines = const LineSplitter().convert(text);
    final startLine = args.getInt('start_line', defaultValue: 1).clamp(1, lines.isEmpty ? 1 : lines.length);
    final maxLines = args.getInt('max_lines', defaultValue: 400).clamp(1, 5000);
    final end = startLine - 1 + maxLines > lines.length
        ? lines.length
        : startLine - 1 + maxLines;

    final buffer = StringBuffer();
    for (var i = startLine - 1; i < end; i++) {
      buffer.writeln('${i + 1}\t${lines[i]}');
    }
    final header = '文件: $path（共 ${lines.length} 行，显示 $startLine-$end）';
    final tail = end < lines.length ? '\n...还有 ${lines.length - end} 行，用 start_line: ${end + 1} 继续' : '';
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

  static const _skippedDirs = {'.git', 'node_modules', 'build', 'dist', '.dart_tool', '__pycache__', 'target'};

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
        if (!isDir && patterns.isNotEmpty && !patterns.any((r) => r.hasMatch(base))) {
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
    if (entries == 0) return ToolResult.success('$out\n（该目录下没有匹配的条目，跳过 $skipped 个）');
    return ToolResult.success('$out\n共 $entries 个条目${skipped > 0 ? "，跳过 $skipped 个" : ""}');
  }

  static RegExp? _globToRegExp(String glob) {
    if (glob.trim().isEmpty) return null;
    final escaped = RegExp.escape(glob.trim()).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
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
  LocalFileSearchTool({super.extraRoots});

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

  static const _skippedDirs = {'.git', 'node_modules', 'build', 'dist', '.dart_tool', '__pycache__', 'target'};

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async {
    final rawPath = args.getString('path');
    final query = args.getString('query');
    if (query.isEmpty) return ToolResult.failure('参数缺失: query 必填');

    final resolved = await _resolve(rawPath, _policy);
    if (resolved is ToolResult) return resolved;
    final path = (resolved as LocalPathDecision).resolved;

    final ignoreCase = args.getBool('ignore_case');
    final maxMatches = args.getInt('max_matches', defaultValue: 100).clamp(1, 1000);
    final needle = ignoreCase ? query.toLowerCase() : query;
    final patterns = args
        .getStringList('glob')
        .map((g) {
          final escaped = RegExp.escape(g.trim()).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
          return RegExp('^$escaped\$', caseSensitive: !Platform.isWindows);
        })
        .toList();

    final files = <String>[];
    var walkCapped = false;
    final entity =  _kindOf(path);
    if (entity == _PathKind.missing) {
      return ToolResult.failure('路径不存在: $path');
    }
    if (entity == _PathKind.file) {
      files.add(path);
    } else {
      await for (final c in Directory(path).list(recursive: true, followLinks: false)) {
        if (c is! File) continue;
        if (_skippedDirs.any((d) => p.split(c.path).contains(d))) continue;
        if (patterns.isNotEmpty && !patterns.any((r) => r.hasMatch(p.basename(c.path)))) continue;
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
    var scanned = 0;
    for (final f in files) {
      if (hits.length >= maxMatches) break;
      scanned++;
      // 流式逐行搜索：不再把每个文件整体读入并 split，命中上限时提前停止
      await _scanFileLines(
        file: f,
        needle: needle,
        ignoreCase: ignoreCase,
        hits: hits,
        maxMatches: maxMatches,
        root: path,
      );
      if (scanned % 200 == 0) onProgress?.call('已扫描 $scanned 个文件...');
    }

    final walkNote = walkCapped ? '\n注意: 文件数已达 5000 上限，未继续遍历，请用 glob 或更窄的 path 缩小范围' : '';
    if (hits.isEmpty) {
      return ToolResult.success(
          '未命中。搜索 "$query"，扫描 ${files.length} 个文件（$path）$walkNote');
    }
    final more = hits.length >= maxMatches ? '\n...已达 $maxMatches 条上限，用 glob 缩小范围' : '';
    return ToolResult.success(
        '${hits.length} 处命中（扫描 ${files.length} 个文件）\n${hits.join('\n')}$more$walkNote');
  }

  String _rel(String file, String root) {
    if ( _kindOf(root) == _PathKind.file) return file;
    final rel = p.relative(file, from: root);
    return rel;
  }

  Future<void> _scanFileLines({
    required String file,
    required String needle,
    required bool ignoreCase,
    required List<String> hits,
    required int maxMatches,
    required String root,
  }) async {
    try {
      final stat = File(file).statSync();
      if (stat.size > 2 * 1024 * 1024) return; // 二进制/超大：跳过而不是失败
      var lineNo = 0;
      await for (final line in File(file)
          .openRead()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())) {
        lineNo++;
        final haystack = ignoreCase ? line.toLowerCase() : line;
        if (!haystack.contains(needle)) continue;
        final text = line.length > 200 ? '${line.substring(0, 200)}…' : line;
        hits.add('${_rel(file, root)}:$lineNo: $text');
        if (hits.length >= maxMatches) break;
      }
    } catch (_) {
      // 无权限/非 UTF-8：跳过该文件
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
  LocalFileWriteTool({super.extraRoots});

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
          'mode': {'type': 'string', 'enum': ['write', 'append']},
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
      return ToolResult.failure('未知 mode: $mode（支持 write/append）');
    }
    final resolved = await _resolve(rawPath, _policy);
    if (resolved is ToolResult) return resolved;
    final path = (resolved as LocalPathDecision).resolved;

    final content = decodeContent(
      plain: decodeEscapedText(args.getString('content')),
      b64: args.getString('content_b64'),
    );
    if (content.isFailed) return ToolResult.failure(content.error!);
    if (content.bytes.isEmpty && mode == 'write' && !args.containsKey('content') && !args.containsKey('content_b64')) {
      return ToolResult.failure('参数缺失: content 或 content_b64 必须提供一个。'
          '多行内容请写在同一行并用 \\n 表示换行。');
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
  LocalFilePatchTool({super.extraRoots});

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
    final resolved = await _resolve(rawPath, _policy);
    if (resolved is ToolResult) return resolved;
    final path = (resolved as LocalPathDecision).resolved;

    final oldPlain = decodeEscapedText(args.getString('old'));
    final newPlain = decodeEscapedText(args.getString('new'));
    final oldB64 = args.getString('old_b64');
    final newB64 = args.getString('new_b64');

    final oldDecoded = decodeContent(plain: oldPlain, b64: oldB64);
    final newDecoded = decodeContent(plain: newPlain, b64: newB64);
    if (oldDecoded.isFailed) return ToolResult.failure(oldDecoded.error!);
    if (newDecoded.isFailed) return ToolResult.failure(newDecoded.error!);

    if (oldPlain.isEmpty && oldB64.isEmpty) {
      return ToolResult.failure('参数缺失: old 或 old_b64 必须提供');
    }

    final outcome = await patchLocalFile(
      path: path,
      oldText: utf8Decode(oldDecoded.bytes),
      newText: utf8Decode(newDecoded.bytes),
      backup: args.getBool('backup', defaultValue: true),
    );
    if (!outcome.success) return ToolResult.failure(outcome.error ?? '替换失败');

    final diff = LineDiff.compute(outcome.oldText ?? '', outcome.newText ?? '');
    final diffText = diff == null ? '' : '（+${diff.additions} -${diff.deletions} 行）';
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

    final type =  _kindOf(srcPath);
    if (type == _PathKind.missing) {
      return ToolResult.failure('源不存在: $srcPath');
    }
    final exists =  _kindOf(dstPath) != _PathKind.missing;
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

    final type =  _kindOf(path);
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
  final type =  _kindOf(path);
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
