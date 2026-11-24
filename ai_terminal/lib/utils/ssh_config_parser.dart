/// OpenSSH `~/.ssh/config` 的只读解析器（导入用最小子集）。
///
/// 语义按 OpenSSH 实现：`Host` 块按文件顺序生效，同一主机的同一指令**先出现者生效**，
/// 通配块（`Host *`）对匹配到的别名提供缺省值。`Include` 由调用方注入解析器
/// （解析器不碰 dart:io，保持可单测），展开后就地splice 到当前位置以保持顺序。
///
/// 只取「连上哪台机器」所需：HostName/Port/User/IdentityFile/ProxyJump。
/// 其余指令归入 ignoredKeys，由 UI 告知用户「这些不会带过来」。
library;

import '../models/host_config.dart';

/// 一条可导入的主机（尚未落库，不含凭据）
class SshConfigEntry {
  /// `Host` 行的别名，作为展示名与匹配名
  final String alias;
  final String host;
  final int port;
  final String username;

  /// `IdentityFile` 原始值（可能含 `~`），仅用于展示；
  /// 私钥内容必须由用户在编辑页选择文件后才能入库
  final String? identityFile;

  /// `ProxyJump` 的首跳别名（导入时尽力解析为已导入主机的别名）
  final String? proxyJump;

  /// 本条主机上被忽略的指令名（去重），供 UI 提示
  final List<String> ignoredKeys;

  const SshConfigEntry({
    required this.alias,
    required this.host,
    required this.port,
    required this.username,
    this.identityFile,
    this.proxyJump,
    this.ignoredKeys = const [],
  });

  bool get hasPrivateKey => identityFile != null && identityFile!.isNotEmpty;
}

class SshConfigParseResult {
  final List<SshConfigEntry> entries;
  final List<String> warnings;

  const SshConfigParseResult({required this.entries, required this.warnings});
}

/// `Include` 解析结果：一个具体文件的路径与内容
class SshConfigIncludedFile {
  final String path;
  final String content;
  const SshConfigIncludedFile(this.path, this.content);
}

/// 把 Include 的模式（可能含 `~` 与 glob）展开成可读文件列表。
/// 返回的 [SshConfigIncludedFile.path] 用于告警定位。
typedef SshConfigIncludeResolver = List<SshConfigIncludedFile> Function(
    String pattern, String homeDir);

const _supportedKeys = {
  'hostname',
  'port',
  'user',
  'identityfile',
  'proxyjump',
};

/// 导入后主机的默认分组名
const sshConfigImportGroup = 'SSH 配置';

SshConfigParseResult parseSshConfig(
  String content, {
  required String homeDir,
  SshConfigIncludeResolver? includeResolver,
}) {
  final warnings = <String>[];
  final blocks = _parseBlocks(content,
      homeDir: homeDir,
      includeResolver: includeResolver,
      warnings: warnings,
      depth: 0);
  return _fromBlocks(blocks, warnings);
}

class _Block {
  final List<String> patterns;
  final List<List<String>> options = [];
  _Block(this.patterns);
}

List<_Block> _parseBlocks(
  String content, {
  required String homeDir,
  required SshConfigIncludeResolver? includeResolver,
  required List<String> warnings,
  required int depth,
}) {
  final blocks = <_Block>[];
  // 首个 Host 之前的指令在 OpenSSH 里是「所有主机的缺省值」，
  // 用一个隐式 Host * 块承接，语义一致且复用同一套合并逻辑。
  _Block? globalDefaults;
  _Block? current;
  // Match 之后的指令是条件生效的，无法归到某台具体主机：
  // 置 true 后跳过所有指令，直到下一个 Host。
  var inMatch = false;
  final lines = content.split(RegExp(r'\r\n|\r|\n'));

  for (var i = 0; i < lines.length; i++) {
    final line = _stripComment(lines[i]).trim();
    if (line.isEmpty) continue;
    final kv = _parseKeyValue(line);
    if (kv == null) {
      warnings.add('第 ${i + 1} 行无法解析: $line');
      continue;
    }
    final key = kv.$1.toLowerCase();
    final value = kv.$2;

    if (key == 'host') {
      inMatch = false;
      final patterns =
          value.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
      if (patterns.isEmpty) {
        warnings.add('第 ${i + 1} 行 Host 缺少模式');
        current = null;
        continue;
      }
      current = _Block(patterns);
      blocks.add(current);
      continue;
    }

    if (key == 'match') {
      warnings.add('已忽略 Match 块（第 ${i + 1} 行）及其后的条件指令');
      inMatch = true;
      current = null;
      continue;
    }

    if (inMatch) continue;

    if (key == 'include') {
      // Include 就地展开：被包含文件的块插到当前位置之后，
      // 以保持「同一指令先出现者生效」的全局顺序
      if (depth >= 3) {
        warnings.add('Include 层级过深，已停止展开: $value');
        continue;
      }
      if (includeResolver == null) {
        warnings.add('存在 Include $value，但未展开（未提供文件读取能力）');
        continue;
      }
      final List<SshConfigIncludedFile> files;
      try {
        files = includeResolver(value, homeDir);
      } catch (e) {
        warnings.add('Include $value 展开失败: $e');
        continue;
      }
      if (files.isEmpty) warnings.add('Include 未匹配到文件: $value');
      final sub = <_Block>[];
      for (final f in files) {
        sub.addAll(_parseBlocks(f.content,
            homeDir: homeDir,
            includeResolver: includeResolver,
            warnings: warnings,
            depth: depth + 1));
      }
      blocks.insertAll(blocks.length, sub);
      continue;
    }

    final target = current ??= globalDefaults ??= _Block(const ['*']);
    if (current == globalDefaults && !blocks.contains(target)) {
      blocks.insert(0, target);
    }
    // 同一块内同一指令重复出现：OpenSSH 取首个，后续忽略
    if (!target.options.any((o) => o.first == key)) {
      target.options.add([key, value]);
    }
  }
  return blocks;
}

SshConfigParseResult _fromBlocks(List<_Block> blocks, List<String> warnings) {
  final entries = <SshConfigEntry>[];
  final concreteAliases = <String>{};
  for (final b in blocks) {
    concreteAliases.addAll(b.patterns.where(_isConcrete));
  }

  for (final alias in concreteAliases) {
    // 匹配该别名的块按文件顺序合并，同一指令先出现者生效
    final resolved = <String, String>{};
    final ignored = <String>[];
    final shadowedBy = <String, String>{};
    for (final b in blocks) {
      if (!b.patterns.any((p) => _patternMatches(p, alias))) continue;
      for (final opt in b.options) {
        final key = opt[0];
        if (resolved.containsKey(key)) {
          // 后置块的同一指令被更早的块吃掉（键 = 更早的块，值 = 被忽略的值）
          shadowedBy[key] ??= '${b.patterns.join(' ')} = ${opt[1]}';
          continue;
        }
        resolved[key] = opt[1];
        if (!_supportedKeys.contains(key) && !ignored.contains(key)) {
          ignored.add(key);
        }
      }
    }

    // 前置通配块遮蔽了具体主机自己写的值：OpenSSH 就这么连的，
    // 但导入结果会和用户肉眼看到的配置不一致，必须在 UI 里说清楚
    for (final entry in shadowedBy.entries) {
      if (_supportedKeys.contains(entry.key)) {
        warnings.add('$alias: 后文的 ${entry.value} 未生效'
            '（OpenSSH 对同一指令取先出现者）');
      }
    }

    final portRaw = resolved['port'];
    var port = 22;
    if (portRaw != null) {
      final parsed = int.tryParse(portRaw.trim());
      if (parsed == null || parsed <= 0 || parsed > 65535) {
        warnings.add('$alias: Port「$portRaw」非法，回退 22');
      } else {
        port = parsed;
      }
    }

    final host = (resolved['hostname'] ?? alias).trim();
    if (host.isEmpty || !_isConcrete(host)) {
      warnings.add('$alias: HostName「$host」不是具体地址，已跳过');
      continue;
    }
    final username = (resolved['user'] ?? '').trim();
    if (username.isEmpty) {
      warnings.add('$alias: 未配置 User，已跳过（导入后可在编辑页填写）');
      continue;
    }

    var proxyJump = resolved['proxyjump']?.split(',').first.trim();
    if (proxyJump != null && proxyJump.contains('@')) {
      proxyJump = proxyJump.substring(proxyJump.indexOf('@') + 1);
    }
    if (proxyJump != null && proxyJump.isEmpty) proxyJump = null;

    entries.add(SshConfigEntry(
      alias: alias,
      host: host,
      port: port,
      username: username,
      identityFile: resolved['identityfile']?.trim(),
      proxyJump: proxyJump,
      ignoredKeys: ignored,
    ));
  }
  return SshConfigParseResult(entries: entries, warnings: warnings);
}

/// 由导入条目构造待落库的 HostConfig。
/// id 由调用方生成；私钥/密码需另行经 CredentialsStore 入库（R7：不落明文）。
HostConfig buildHostConfig({
  required SshConfigEntry entry,
  required String id,
  String group = sshConfigImportGroup,
}) {
  final jump = entry.proxyJump;
  return HostConfig.create(
    id: id,
    name: entry.alias,
    host: entry.host,
    port: entry.port,
    username: entry.username,
    authType: entry.hasPrivateKey ? 'privateKey' : 'password',
    group: group,
    // 跳板机的用户名/认证在 ssh_config 里属于另一个 Host 块，
    // 导入时只带地址，其余留给用户在编辑页确认
    jumpHost: jump == null || jump == entry.alias ? null : jump,
  );
}

bool _isConcrete(String pattern) =>
    !pattern.contains('*') &&
    !pattern.contains('?') &&
    !pattern.startsWith('!');

/// ssh_config 的 glob：`*` 任意串，`?` 单字符
bool _patternMatches(String pattern, String alias) {
  if (pattern == alias) return true;
  if (_isConcrete(pattern)) return false;
  final sb = StringBuffer('^');
  for (final ch in pattern.split('')) {
    if (ch == '*') {
      sb.write('.*');
    } else if (ch == '?') {
      sb.write('.');
    } else {
      sb.write(RegExp.escape(ch));
    }
  }
  sb.write(r'$');
  return RegExp(sb.toString()).hasMatch(alias);
}

/// ssh_config 的 `#` 注释只在行首或空白后生效（值里可以含 `#`）
String _stripComment(String line) {
  final m = RegExp(r'(?:^|\s)#').firstMatch(line);
  return m == null ? line : line.substring(0, m.start);
}

/// 支持 `Key value`、`Key=value`、`Key "value"` 三种写法
(String, String)? _parseKeyValue(String line) {
  final m = RegExp(r'^([A-Za-z][A-Za-z0-9_-]*)\s*=?\s*(.*)$').firstMatch(line);
  if (m == null) return null;
  var value = m.group(2)!.trim();
  if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
    value = value.substring(1, value.length - 1);
  }
  if (value.isEmpty) return null;
  return (m.group(1)!, value);
}
