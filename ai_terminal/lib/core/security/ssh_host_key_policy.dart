import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/ssh_host_key.dart';

class SshHostKeyPolicyException implements Exception {
  const SshHostKeyPolicyException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SshHostKeyPolicy {
  static const directRoute = 'direct';
  static const localUser = 'local-user';
  static const allowedKeyTypes = {
    'ssh-ed25519',
    'ecdsa-sha2-nistp256',
    'ecdsa-sha2-nistp384',
    'ecdsa-sha2-nistp521',
    'rsa-sha2-256',
    'rsa-sha2-512',
  };

  static String alias(String host, int port) {
    final normalized =
        host.trim().toLowerCase().replaceAll(RegExp(r'\.+$'), '');
    if (normalized.isEmpty) {
      throw const SshHostKeyPolicyException('SSH 主机地址为空');
    }
    if (port < 1 || port > 65535) {
      throw const SshHostKeyPolicyException('SSH 端口无效');
    }
    if (normalized.contains(':')) return '[$normalized]:$port';
    return port == 22 ? normalized : '$normalized:$port';
  }

  static String jumpRoute({
    required String username,
    required String host,
    required int port,
  }) {
    if (username.trim().isEmpty) {
      throw const SshHostKeyPolicyException('SSH 跳板用户名为空');
    }
    return 'jump[${username.trim()}@${alias(host, port)}]';
  }

  static bool isHashedAlias(String alias) => alias.startsWith('|1|');

  static bool matchesAlias(String storedAlias, String candidateAlias) {
    if (storedAlias == candidateAlias) return true;
    if (!isHashedAlias(storedAlias)) return false;
    final parts = storedAlias.split('|');
    if (parts.length != 4 || parts[0].isNotEmpty || parts[1] != '1') {
      return false;
    }
    try {
      final salt =
          base64.decode(parts[2].padRight((parts[2].length + 3) ~/ 4 * 4, '='));
      final expected =
          base64.decode(parts[3].padRight((parts[3].length + 3) ~/ 4 * 4, '='));
      if (salt.length != 20 || expected.length != 20) return false;
      final actual =
          Hmac(sha1, salt).convert(utf8.encode(candidateAlias)).bytes;
      var difference = 0;
      for (var i = 0; i < expected.length; i++) {
        difference |= expected[i] ^ actual[i];
      }
      return difference == 0;
    } on FormatException {
      return false;
    }
  }

  static String normalizeFingerprint(String fingerprint) {
    final value = fingerprint.trim();
    if (!value.startsWith('SHA256:')) {
      throw const SshHostKeyPolicyException('SSH 主机密钥指纹格式无效');
    }
    final encoded = value.substring(7);
    if (!RegExp(r'^[A-Za-z0-9+/]{43}=?$').hasMatch(encoded)) {
      throw const SshHostKeyPolicyException('SSH 主机密钥指纹格式无效');
    }
    final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
    try {
      final digest = base64.decode(padded);
      if (digest.length != 32) throw const FormatException();
      return 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
    } on FormatException {
      throw const SshHostKeyPolicyException('SSH 主机密钥指纹格式无效');
    }
  }

  static String normalizeFingerprintBytes(List<int> bytes) {
    try {
      return normalizeFingerprint(utf8.decode(bytes));
    } on FormatException {
      throw const SshHostKeyPolicyException('SSH 主机密钥指纹不是有效的 UTF-8');
    }
  }

  static void validateKeyType(String keyType) {
    if (!allowedKeyTypes.contains(keyType)) {
      throw SshHostKeyPolicyException('不支持的 SSH 主机密钥算法: $keyType');
    }
  }

  static SshHostKey newTrust({
    required String routeKey,
    required String alias,
    required String keyType,
    required String fingerprintSha256,
    required SshHostKeySource source,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    return SshHostKey(
      routeKey: routeKey,
      alias: alias,
      keyType: keyType,
      fingerprintSha256: normalizeFingerprint(fingerprintSha256),
      firstSeenAt: timestamp,
      lastSeenAt: timestamp,
      status: SshHostKeyStatus.trusted,
      source: source,
      confirmedBy: localUser,
    );
  }
}
