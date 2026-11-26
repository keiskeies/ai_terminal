import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../models/ssh_host_key.dart';
import 'ssh_host_key_policy.dart';
import 'ssh_host_key_store.dart';

enum KnownHostsAction { add, revoke, unchanged, conflict }

class KnownHostsIssue {
  const KnownHostsIssue({required this.line, required this.message});

  final int line;
  final String message;
}

class KnownHostsEntry {
  const KnownHostsEntry({
    required this.id,
    required this.line,
    required this.alias,
    required this.keyType,
    required this.fingerprintSha256,
    required this.publicKeyBase64,
    required this.revoked,
  });

  final String id;
  final int line;
  final String alias;
  final String keyType;
  final String fingerprintSha256;
  final String publicKeyBase64;
  final bool revoked;

  bool get isHashed => SshHostKeyPolicy.isHashedAlias(alias);
}

class KnownHostsPreviewItem {
  const KnownHostsPreviewItem({
    required this.entry,
    required this.action,
    this.existing,
  });

  final KnownHostsEntry entry;
  final KnownHostsAction action;
  final SshHostKey? existing;
}

class KnownHostsParsed {
  const KnownHostsParsed({required this.entries, required this.issues});

  final List<KnownHostsEntry> entries;
  final List<KnownHostsIssue> issues;
}

class KnownHostsPreview {
  const KnownHostsPreview({required this.items, required this.issues});

  final List<KnownHostsPreviewItem> items;
  final List<KnownHostsIssue> issues;
}

class KnownHostsExportResult {
  const KnownHostsExportResult({required this.content, required this.skipped});

  final String content;
  final List<String> skipped;
}

class KnownHostsService {
  KnownHostsService(this._store);

  final SshHostKeyStore _store;

  KnownHostsParsed parse(String content) {
    final entries = <KnownHostsEntry>[];
    final issues = <KnownHostsIssue>[];
    final lines = const LineSplitter().convert(content);
    for (var index = 0; index < lines.length; index++) {
      final lineNumber = index + 1;
      final line = lines[index].split('#').first.trim();
      if (line.isEmpty) continue;
      final fields = line.split(RegExp(r'\s+'));
      var revoked = false;
      if (fields.first.startsWith('@')) {
        if (fields.first == '@revoked') {
          revoked = true;
          fields.removeAt(0);
        } else {
          issues.add(KnownHostsIssue(
              line: lineNumber,
              message: '不支持的 known_hosts 标记: ${fields.first}'));
          continue;
        }
      }
      if (fields.length < 3) {
        issues
            .add(KnownHostsIssue(line: lineNumber, message: '字段不足，需要地址、算法和公钥'));
        continue;
      }
      final wireType = fields[1];
      final keyTypes = switch (wireType) {
        'ssh-rsa' => ['rsa-sha2-256', 'rsa-sha2-512'],
        _ when SshHostKeyPolicy.allowedKeyTypes.contains(wireType) => [
            wireType
          ],
        _ => <String>[],
      };
      if (keyTypes.isEmpty) {
        issues.add(
            KnownHostsIssue(line: lineNumber, message: '不支持的算法: $wireType'));
        continue;
      }
      final Uint8List publicKey;
      try {
        publicKey = base64.decode(fields[2]);
        _validatePublicKey(publicKey, wireType);
      } on FormatException {
        issues.add(
            KnownHostsIssue(line: lineNumber, message: '公钥 base64 或 SSH 编码无效'));
        continue;
      }
      final fingerprint = SshHostKeyPolicy.normalizeFingerprint(
          'SHA256:${base64.encode(sha256.convert(publicKey).bytes).replaceAll('=', '')}');
      final aliases = fields[0].split(',');
      for (var aliasIndex = 0; aliasIndex < aliases.length; aliasIndex++) {
        final String? alias;
        try {
          alias = _normalizeAlias(aliases[aliasIndex]);
        } on SshHostKeyPolicyException catch (error) {
          issues.add(KnownHostsIssue(line: lineNumber, message: error.message));
          continue;
        }
        for (final keyType in keyTypes) {
          entries.add(KnownHostsEntry(
            id: '$lineNumber:$aliasIndex:$keyType',
            line: lineNumber,
            alias: alias,
            keyType: keyType,
            fingerprintSha256: fingerprint,
            publicKeyBase64: base64.encode(publicKey),
            revoked: revoked,
          ));
        }
      }
    }
    return KnownHostsParsed(entries: entries, issues: issues);
  }

  Future<KnownHostsPreview> preview(
    String content, {
    required String routeKey,
  }) async {
    _validateRoute(routeKey);
    final parsed = parse(content);
    final existing = await _store.getAll();
    final items = <KnownHostsPreviewItem>[];
    for (final entry in parsed.entries) {
      SshHostKey? match;
      for (final key in existing) {
        if (key.routeKey == routeKey &&
            key.keyType == entry.keyType &&
            SshHostKeyPolicy.matchesAlias(key.alias, entry.alias)) {
          match = key;
          break;
        }
      }
      final action = _action(entry, match);
      items.add(
          KnownHostsPreviewItem(entry: entry, action: action, existing: match));
    }
    return KnownHostsPreview(items: items, issues: parsed.issues);
  }

  Future<SshHostKeyImportResult> import(
    String content, {
    required String routeKey,
    required Set<String> acceptedIds,
  }) async {
    final preview = await this.preview(content, routeKey: routeKey);
    final now = DateTime.now();
    final keys = <SshHostKey>[];
    for (final item in preview.items) {
      if (!acceptedIds.contains(item.entry.id) ||
          (item.action != KnownHostsAction.add &&
              item.action != KnownHostsAction.revoke)) {
        continue;
      }
      final entry = item.entry;
      keys.add(SshHostKeyPolicy.newTrust(
        routeKey: routeKey,
        alias: entry.alias,
        keyType: entry.keyType,
        fingerprintSha256: entry.fingerprintSha256,
        source: SshHostKeySource.imported,
        now: now,
      ).copyWith(
        status:
            entry.revoked ? SshHostKeyStatus.revoked : SshHostKeyStatus.trusted,
        confirmedBy: 'known_hosts-import',
        publicKeyBase64: entry.publicKeyBase64,
      ));
    }
    if (keys.isEmpty) {
      return const SshHostKeyImportResult(added: 0, revoked: 0, skipped: 0);
    }
    return _store.importKeys(keys);
  }

  KnownHostsExportResult export(Iterable<SshHostKey> keys) {
    final output = <String>[];
    final skipped = <String>[];
    for (final key in keys) {
      if (key.routeKey != SshHostKeyPolicy.directRoute) {
        skipped.add('${key.alias}: 跳板路由不导出');
        continue;
      }
      final publicKey = key.publicKeyBase64;
      if (publicKey == null || publicKey.isEmpty) {
        skipped.add('${key.alias}: 人工确认记录没有完整公钥，不能生成 known_hosts');
        continue;
      }
      if (key.alias.contains(RegExp(r'[\s,]'))) {
        skipped.add('${key.alias}: 地址格式无效');
        continue;
      }
      final wireType = switch (key.keyType) {
        'rsa-sha2-256' || 'rsa-sha2-512' => 'ssh-rsa',
        final type => type,
      };
      final marker = key.status == SshHostKeyStatus.revoked ? '@revoked ' : '';
      try {
        _validatePublicKey(base64.decode(publicKey), wireType);
      } on FormatException {
        skipped.add('${key.alias}: 存储的公钥编码无效');
        continue;
      }
      output.add('$marker${key.alias} $wireType $publicKey');
    }
    return KnownHostsExportResult(
        content: output.isEmpty ? '' : '${output.join('\n')}\n',
        skipped: skipped);
  }
}

KnownHostsAction _action(KnownHostsEntry entry, SshHostKey? existing) {
  if (existing == null) {
    return entry.revoked ? KnownHostsAction.revoke : KnownHostsAction.add;
  }
  if (entry.revoked &&
      existing.status == SshHostKeyStatus.trusted &&
      existing.fingerprintSha256 == entry.fingerprintSha256) {
    return KnownHostsAction.revoke;
  }
  if (!entry.revoked &&
      existing.status == SshHostKeyStatus.trusted &&
      existing.fingerprintSha256 == entry.fingerprintSha256) {
    return KnownHostsAction.unchanged;
  }
  if (entry.revoked &&
      existing.status == SshHostKeyStatus.revoked &&
      existing.fingerprintSha256 == entry.fingerprintSha256) {
    return KnownHostsAction.unchanged;
  }
  return KnownHostsAction.conflict;
}

void _validateRoute(String routeKey) {
  if (routeKey.trim().isEmpty || routeKey.length > 512) {
    throw const SshHostKeyPolicyException('SSH 路由标识无效');
  }
}

String _normalizeAlias(String raw) {
  final value = raw.trim();
  if (value.isEmpty) throw const SshHostKeyPolicyException('known_hosts 地址为空');
  if (value.startsWith('|')) {
    final parts = value.split('|');
    if (parts.length != 4 || parts[0].isNotEmpty || parts[1] != '1') {
      throw const SshHostKeyPolicyException('hashed known_hosts 地址格式无效');
    }
    try {
      final salt = base64.decode(_padBase64(parts[2]));
      final hash = base64.decode(_padBase64(parts[3]));
      if (salt.length != 20 || hash.length != 20) {
        throw const FormatException();
      }
    } on FormatException {
      throw const SshHostKeyPolicyException('hashed known_hosts 地址编码无效');
    }
    return value;
  }
  if (value.contains(RegExp(r'[\s,*?!]'))) {
    throw SshHostKeyPolicyException('known_hosts 不支持通配符或非法地址: $value');
  }
  if (value.startsWith('[')) {
    final match = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(value);
    if (match == null) {
      throw const SshHostKeyPolicyException('known_hosts 括号地址格式无效');
    }
    return SshHostKeyPolicy.alias(
        match.group(1)!, int.parse(match.group(2) ?? '22'));
  }
  final colon = value.indexOf(':');
  if (colon >= 0 && colon == value.lastIndexOf(':')) {
    final port = int.tryParse(value.substring(colon + 1));
    if (port == null) {
      throw const SshHostKeyPolicyException('known_hosts 端口格式无效');
    }
    return SshHostKeyPolicy.alias(value.substring(0, colon), port);
  }
  return SshHostKeyPolicy.alias(value, 22);
}

String _padBase64(String value) =>
    value.padRight((value.length + 3) ~/ 4 * 4, '=');

void _validatePublicKey(Uint8List publicKey, String expectedType) {
  if (publicKey.length < 4) throw const FormatException();
  final length = ByteData.sublistView(publicKey).getUint32(0);
  if (length == 0 || length > publicKey.length - 4) {
    throw const FormatException();
  }
  final type = utf8.decode(publicKey.sublist(4, 4 + length));
  if (type != expectedType) throw const FormatException();
}
