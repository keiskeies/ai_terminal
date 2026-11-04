import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 本地文件操作的共享原语
///
/// 这些函数同时服务两类调用方：
/// - `local_*` 工具（受 LocalFilePolicy 白名单约束，只碰本机）
/// - `file_write` / `file_patch` 的本地分支（本地终端会话）
///
/// 备份与转义规则必须只有一份实现：两处各写一遍的话，其中一处改了备份命名或
/// `\n` 转义语义，另一处就会静默漂移（AGENTS.md R8-3「双重清洗」就是同型问题）。

/// 还原单行参数中的转义序列：`\n` `\r` `\t` `\\`。未知序列原样保留。
///
/// AI 把多行内容写在 `content: ` 一行里时用的就是这个约定；
/// 让 AI 自己算 base64 反而更容易出错，所以 base64 只留给二进制与逐字节场景。
String decodeEscapedText(String text) {
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (ch != '\\' || i == text.length - 1) {
      buffer.write(ch);
      continue;
    }
    final next = text[++i];
    switch (next) {
      case 'n':
        buffer.write('\n');
      case 'r':
        buffer.write('\r');
      case 't':
        buffer.write('\t');
      case '\\':
        buffer.write('\\');
      default:
        buffer.write('\\');
        buffer.write(next);
    }
  }
  return buffer.toString();
}

/// 从 content / content_b64 两种写法解出待写字节（[error] 非空表示失败）
class DecodedContent {
  final List<int> bytes;
  final String? error;
  const DecodedContent(this.bytes, {this.error});
  bool get isFailed => error != null;
}

/// 两者都给时以 base64 为准 —— 调用方明确表达了逐字节意图。
DecodedContent decodeContent({required String plain, required String b64}) {
  if (b64.isNotEmpty) {
    try {
      return DecodedContent(base64Decode(b64));
    } on FormatException catch (e) {
      return DecodedContent(const [], error: 'base64 解码失败: ${e.message}');
    }
  }
  return DecodedContent(utf8.encode(plain));
}

/// 备份本地文件到同目录 `.bak.{microseconds}`，返回备份路径
Future<String> backupLocalFile(String path) async {
  final backupPath = '$path.bak.${DateTime.now().microsecondsSinceEpoch}';
  await File(path).copy(backupPath);
  return backupPath;
}

/// 写入结果（含备份路径与失败原因），供调用方拼 ToolResult 文案
class LocalWriteOutcome {
  final bool success;
  final String? backupPath;
  final int bytesWritten;
  final String? error;
  const LocalWriteOutcome({
    required this.success,
    this.backupPath,
    this.bytesWritten = 0,
    this.error,
  });
}

/// 就地写入本机文件（保留 inode/权限），失败时从备份回滚。
///
/// 为什么不用 tmp+rename：rename 会丢掉属主与 ACL，且 Windows 上目标已存在时
/// rename 直接失败。这里与既有 `file_write` 保持一致 —— 先备份、就地写、
/// 写完校验字节数，任何一步失败都把备份拷回去。
Future<LocalWriteOutcome> writeLocalFile({
  required String path,
  required List<int> bytes,
  bool append = false,
  bool backup = true,

  /// 备份步骤的可注入点。生产路径不传，走 [backupLocalFile]。
  ///
  /// 备份失败必须中止写入，但真要把备份弄失败只能靠文件锁 / 超长路径 / ACL 这类
  /// 平台相关且不稳的手段 —— 用注入点换一条确定性的安全断言更值。
  @visibleForTesting Future<String> Function(String path)? backupForTesting,
}) async {
  final file = File(path);
  final exists = await file.exists();

  if (append && !exists) {
    return const LocalWriteOutcome(
      success: false,
      error: 'append 模式要求文件已存在。请先用 mode=write 创建文件，再用 mode=append 追加后续块。',
    );
  }

  String? backupPath;
  if (!append && backup && exists) {
    try {
      backupPath =
          await (backupForTesting ?? backupLocalFile)(path);
    } catch (e) {
      // 备份失败即中止：没有回滚路径的覆盖写入不可接受
      return LocalWriteOutcome(
          success: false, error: '备份原文件失败: $e。已中止写入，原文件未被修改。');
    }
  }

  try {
    if (!append) {
      final parentDir = p.dirname(path);
      if (parentDir.isNotEmpty && parentDir != '.') {
        await Directory(parentDir).create(recursive: true);
      }
    }
    await file.writeAsBytes(bytes,
        mode: append ? FileMode.append : FileMode.write, flush: true);
  } catch (e) {
    if (backupPath != null) {
      try {
        await File(backupPath).copy(path);
        return LocalWriteOutcome(
          success: false,
          backupPath: backupPath,
          error: '写入失败: $e\n已自动回滚：原文件已从备份 $backupPath 恢复。',
        );
      } catch (rollbackErr) {
        return LocalWriteOutcome(
          success: false,
          backupPath: backupPath,
          error: '写入失败: $e\n回滚也失败: $rollbackErr。请手动用备份 $backupPath 恢复 $path',
        );
      }
    }
    return LocalWriteOutcome(success: false, error: '写入失败: $e');
  }

  // 写完校验：写入被中断时长度会短于预期，静默截断比报错更难查
  int? actual;
  try {
    actual = await file.length();
  } catch (e) {
    debugPrint('[LocalFileOps] 写入后取长度失败: $e');
  }
  if (!append && actual != null && actual != bytes.length) {
    if (backupPath != null) {
      try {
        await File(backupPath).copy(path);
      } catch (_) {
        // 回滚再失败时，下面的错误文案里已经带了备份路径
      }
    }
    return LocalWriteOutcome(
      success: false,
      backupPath: backupPath,
      error: '写入后校验失败：期望 ${bytes.length} 字节，实际 $actual 字节。'
          '${backupPath != null ? "已从备份 $backupPath 回滚。" : "该文件是新建的，无需回滚。"}',
    );
  }

  return LocalWriteOutcome(
    success: true,
    backupPath: backupPath,
    bytesWritten: actual ?? bytes.length,
  );
}

/// 统计 substring 在 string 中出现的次数（非重叠）
int countOccurrences(String string, String sub) {
  if (sub.isEmpty) return 0;
  var count = 0;
  var idx = 0;
  while (true) {
    final found = string.indexOf(sub, idx);
    if (found < 0) break;
    count++;
    idx = found + sub.length;
  }
  return count;
}

/// 字符串替换式补丁的结果
class LocalPatchOutcome {
  final bool success;
  final String? error;
  final String? backupPath;
  final String? oldText;
  final String? newText;
  const LocalPatchOutcome({
    required this.success,
    this.error,
    this.backupPath,
    this.oldText,
    this.newText,
  });
}

/// 唯一性替换 + 写前二次 stat（防覆盖外部修改）
Future<LocalPatchOutcome> patchLocalFile({
  required String path,
  required String oldText,
  required String newText,
  bool backup = true,
}) async {
  final file = File(path);
  if (!await file.exists()) {
    return const LocalPatchOutcome(
        success: false, error: '文件不存在，无法做字符串替换。请先确认路径。');
  }
  if (oldText.isEmpty) {
    return const LocalPatchOutcome(success: false, error: 'old 不能为空');
  }

  final statBefore = await file.stat();
  final String original;
  try {
    original = await file.readAsString();
  } catch (e) {
    return LocalPatchOutcome(
        success: false, error: '读取文件失败（可能是二进制文件或编码不是 UTF-8）: $e');
  }

  final hits = countOccurrences(original, oldText);
  if (hits == 0) {
    return const LocalPatchOutcome(
      success: false,
      error: '未找到要替换的内容。请先用 local_file_read 确认原文（注意缩进与换行）。',
    );
  }
  if (hits > 1) {
    return LocalPatchOutcome(
      success: false,
      error: '要替换的内容在文件中出现 $hits 次，无法定位。请提供更长的上下文使其唯一。',
    );
  }

  // 读与写之间被外部改过就放弃，避免覆盖别人的更新
  final statNow = await file.stat();
  if (statNow.size != statBefore.size || statNow.modified != statBefore.modified) {
    return const LocalPatchOutcome(
      success: false,
      error: '文件在读取后被外部修改（大小或修改时间变了）。已中止写入，请重新读取后再试。',
    );
  }

  String? backupPath;
  if (backup) {
    try {
      backupPath = await backupLocalFile(path);
    } catch (e) {
      return LocalPatchOutcome(
          success: false, error: '备份原文件失败: $e。已中止写入，原文件未被修改。');
    }
  }

  final write = await writeLocalFile(
    path: path,
    bytes: utf8.encode(original.replaceFirst(oldText, newText)),
    backup: false, // 上面已备份，不再留第二份
  );
  if (!write.success) {
    return LocalPatchOutcome(
      success: false,
      backupPath: backupPath,
      error: write.error,
      oldText: oldText,
      newText: newText,
    );
  }
  return LocalPatchOutcome(
    success: true,
    backupPath: backupPath ?? write.backupPath,
    oldText: oldText,
    newText: newText,
  );
}

/// 回收区条目（`<所在目录>/.ai_terminal_trash/<时间戳>/`）的用量
class TrashUsage {
  const TrashUsage({required this.entries, required this.bytes});

  /// 仍然存在的回收条目目录
  final List<String> entries;
  final int bytes;

  int get count => entries.length;
  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;
}

/// 路径是否是"某个回收条目目录"：位于 `.ai_terminal_trash` 之下，且比它深一层
/// （即 `<stamp>` 那一级），但不再是 `.ai_terminal_trash` 本身。
///
/// 回收区根目录是保留目录，删掉它会让后续删除无处可去。
bool isTrashEntryDir(String path, {required String trashDirName}) {
  final segments = p.split(p.normalize(path));
  final index = segments.lastIndexOf(trashDirName);
  return index >= 0 && index == segments.length - 2;
}

/// 从台账记录的 `localRestoreFrom` 推出回收条目目录（去重、排序）
///
/// 只保留通过 [isTrashEntryDir] 的路径：回收位置是删除时算出来的，台账行若被
/// 异常数据写成一个普通目录（比如用户自己的 `D:\projects`），不加判定地"清空
/// 回收区"就会把真实数据删掉。
List<String> trashEntriesFromRestorePaths(
  Iterable<String> restorePaths, {
  required String trashDirName,
}) {
  final entries = <String>{};
  for (final path in restorePaths) {
    if (path.trim().isEmpty) continue;
    final entry = p.dirname(p.normalize(path));
    if (isTrashEntryDir(entry, trashDirName: trashDirName)) entries.add(entry);
  }
  final result = entries.toList();
  result.sort();
  return result;
}

/// 统计回收条目实际占用的字节（不存在的条目直接跳过，不计入）
Future<TrashUsage> measureTrashEntries(List<String> entries) async {
  final live = <String>[];
  var bytes = 0;
  for (final entry in entries) {
    if (!Directory(entry).existsSync()) continue;
    live.add(entry);
    bytes += await _directoryBytes(entry);
  }
  return TrashUsage(entries: live, bytes: bytes);
}

class TrashClearResult {
  const TrashClearResult({
    required this.removed,
    required this.bytesFreed,
    required this.refused,
    required this.failed,
  });

  final int removed;
  final int bytesFreed;

  /// 判定为"不是回收条目"而拒绝删除的路径
  final List<String> refused;

  /// 在回收区内但删除失败的路径（含原因）
  final List<String> failed;

  bool get isClean => refused.isEmpty && failed.isEmpty;
}

/// 清空回收条目
///
/// 每个路径在删除前重新过一次 [isTrashEntryDir]：调用方传错（或台账数据被污染）
/// 时宁可拒绝，也不能顺手删掉一个不是回收区的目录。
Future<TrashClearResult> clearTrashEntries(
  List<String> entries, {
  required String trashDirName,
}) async {
  final refused = <String>[];
  final failed = <String>[];
  var removed = 0;
  var bytesFreed = 0;

  for (final entry in entries) {
    if (!isTrashEntryDir(entry, trashDirName: trashDirName)) {
      refused.add(entry);
      continue;
    }
    if (!Directory(entry).existsSync()) continue;
    final size = await _directoryBytes(entry);
    try {
      await Directory(entry).delete(recursive: true);
      removed++;
      bytesFreed += size;
    } catch (e) {
      failed.add('$entry（$e）');
    }
  }

  return TrashClearResult(
    removed: removed,
    bytesFreed: bytesFreed,
    refused: refused,
    failed: failed,
  );
}

Future<int> _directoryBytes(String dir) async {
  var sum = 0;
  await for (final entity in Directory(dir).list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    try {
      sum += await entity.length();
    } catch (e) {
      debugPrint('[localFileOps] 读取 $entity 大小失败: $e');
    }
  }
  return sum;
}

/// 字节数的口语化写法，用于"回收区约占用多少"这类提示
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// 有多少条还原路径落在这些回收条目里（用于"清空后有多少记录捞不回来"）
int countPathsUnderEntries(
  Iterable<String> restorePaths,
  List<String> entries,
) {
  if (entries.isEmpty) return 0;
  var count = 0;
  for (final raw in restorePaths) {
    if (raw.trim().isEmpty) continue;
    final path = p.normalize(raw);
    if (entries.any((entry) => p.isWithin(entry, path))) count++;
  }
  return count;
}

/// 看起来是"本机的 Windows 路径"（`D:\x` / `C:/x`）
///
/// 远程主机的 POSIX 路径不会长成这样，所以这个判定没有误伤面：
/// 它专门用来拦"在 SSH 会话里把本机路径交给远程工具"——那种调用会把
/// `D:\deploy\app.conf` 当成一个文件名写到服务器上，还报成功。
bool looksLikeWindowsLocalPath(String path) =>
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path.trim());

/// 看起来是"远程主机的 POSIX 路径"（`/etc/x`、`~/x`）
///
/// 只在 Windows 本机上有意义：Windows 的本地路径不会以 `/` 开头（除 UNC，
/// 这里不覆盖），而 macOS/Linux 的本地路径本来就是 `/` 开头，不能这么判。
bool looksLikePosixRemotePath(String path) {
  final t = path.trim();
  return t.startsWith('/') || t.startsWith('~/');
}
