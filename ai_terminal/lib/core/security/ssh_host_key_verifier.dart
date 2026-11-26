import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/ssh_host_key.dart';
import 'ssh_host_key_policy.dart';
import 'ssh_host_key_store.dart';

class SshHostKeyVerificationException implements Exception {
  const SshHostKeyVerificationException(this.message, {this.existing});

  final String message;
  final SshHostKey? existing;

  @override
  String toString() => message;
}

class SshHostKeyRequest {
  const SshHostKeyRequest({
    required this.id,
    required this.alias,
    required this.routeKey,
    required this.routeLabel,
    required this.keyType,
    required this.fingerprintSha256,
    required this.isJumpHost,
    this.existing,
  });

  final String id;
  final String alias;
  final String routeKey;
  final String routeLabel;
  final String keyType;
  final String fingerprintSha256;
  final bool isJumpHost;
  final SshHostKey? existing;

  String get identityKey => '$routeKey\u0000$alias\u0000$keyType';
}

class SshHostKeyPromptResponse {
  const SshHostKeyPromptResponse.accept({this.replaceExisting = false})
      : accepted = true;

  const SshHostKeyPromptResponse.reject()
      : accepted = false,
        replaceExisting = false;

  final bool accepted;
  final bool replaceExisting;
}

typedef SshHostKeyPromptHandler = Future<SshHostKeyPromptResponse> Function(
  SshHostKeyRequest request,
);

class SshHostKeyPromptService {
  static SshHostKeyPromptHandler? _handler;
  static final Map<String, VoidCallback> _cancellations = {};

  static void setHandler(SshHostKeyPromptHandler? handler) {
    _handler = handler;
    if (handler == null) {
      for (final cancel in _cancellations.values.toList()) {
        cancel();
      }
      _cancellations.clear();
    }
  }

  static void bindCancellation(String id, VoidCallback cancel) {
    _cancellations[id] = cancel;
  }

  static void cancel(String id) {
    _cancellations.remove(id)?.call();
  }

  static Future<SshHostKeyPromptResponse> prompt(
      SshHostKeyRequest request) async {
    final handler = _handler;
    if (handler == null) {
      throw const SshHostKeyVerificationException('当前没有可用的主机密钥确认界面');
    }
    try {
      return await handler(request);
    } finally {
      _cancellations.remove(request.id);
    }
  }
}

int _requestSequence = 0;

String _newRequestId() => 'ssh-host-key-${++_requestSequence}';

class SshHostKeyVerifier {
  SshHostKeyVerifier({
    required SshHostKeyStore store,
    SshHostKeyPromptHandler? prompt,
    this.promptTimeout = const Duration(seconds: 60),
    this.idFactory = _newRequestId,
  })  : _store = store,
        _prompt = prompt;

  final SshHostKeyStore _store;
  final SshHostKeyPromptHandler? _prompt;
  final Duration promptTimeout;
  final String Function() idFactory;
  final Map<String, ({String fingerprint, Future<bool> future})> _pending = {};

  Future<bool> verify({
    required String alias,
    required String routeKey,
    required String routeLabel,
    required String keyType,
    required String fingerprint,
    required bool isJumpHost,
  }) async {
    final String normalizedFingerprint;
    try {
      SshHostKeyPolicy.validateKeyType(keyType);
      normalizedFingerprint =
          SshHostKeyPolicy.normalizeFingerprint(fingerprint);
    } on SshHostKeyPolicyException catch (error) {
      throw SshHostKeyVerificationException(error.message);
    }
    final identity = '$routeKey\u0000$alias\u0000$keyType';
    final pending = _pending[identity];
    if (pending != null) {
      if (pending.fingerprint != normalizedFingerprint) {
        throw const SshHostKeyVerificationException(
            '同一 SSH 主机身份正在确认另一个密钥，已拒绝本次连接');
      }
      return pending.future;
    }
    final future = _verify(
      alias: alias,
      routeKey: routeKey,
      routeLabel: routeLabel,
      keyType: keyType,
      fingerprint: normalizedFingerprint,
      isJumpHost: isJumpHost,
    );
    _pending[identity] = (fingerprint: normalizedFingerprint, future: future);
    try {
      return await future;
    } finally {
      final current = _pending[identity];
      if (current != null && identical(current.future, future)) {
        _pending.remove(identity);
      }
    }
  }

  Future<bool> _verify({
    required String alias,
    required String routeKey,
    required String routeLabel,
    required String keyType,
    required String fingerprint,
    required bool isJumpHost,
  }) async {
    final existing = await _store.find(
      routeKey: routeKey,
      alias: alias,
      keyType: keyType,
    );
    if (existing?.status == SshHostKeyStatus.revoked) {
      throw SshHostKeyVerificationException('该 SSH 主机密钥已被撤销',
          existing: existing);
    }
    if (existing != null && existing.fingerprintSha256 == fingerprint) {
      await _recordSuccessfulUse(existing);
      return true;
    }

    final request = SshHostKeyRequest(
      id: idFactory(),
      alias: alias,
      routeKey: routeKey,
      routeLabel: routeLabel,
      keyType: keyType,
      fingerprintSha256: fingerprint,
      isJumpHost: isJumpHost,
      existing: existing,
    );
    final SshHostKeyPromptResponse response;
    try {
      response = await (_prompt ?? SshHostKeyPromptService.prompt)(request)
          .timeout(promptTimeout);
    } on TimeoutException {
      SshHostKeyPromptService.cancel(request.id);
      throw const SshHostKeyVerificationException('SSH 主机密钥确认超时');
    } on SshHostKeyVerificationException {
      rethrow;
    } catch (error) {
      throw SshHostKeyVerificationException('SSH 主机密钥确认失败: $error');
    }
    if (!response.accepted) {
      throw const SshHostKeyVerificationException('用户拒绝了 SSH 主机密钥');
    }

    final now = DateTime.now();
    if (existing == null) {
      final key = SshHostKeyPolicy.newTrust(
        routeKey: routeKey,
        alias: alias,
        keyType: keyType,
        fingerprintSha256: fingerprint,
        source: SshHostKeySource.userConfirmed,
        now: now,
      );
      if (await _store.trustFirstUse(key)) return true;
      final raced =
          await _store.find(routeKey: routeKey, alias: alias, keyType: keyType);
      if (raced != null &&
          raced.status == SshHostKeyStatus.trusted &&
          raced.fingerprintSha256 == fingerprint) {
        await _recordSuccessfulUse(raced);
        return true;
      }
      throw SshHostKeyVerificationException('确认期间 SSH 主机密钥已变化',
          existing: raced);
    }

    if (!response.replaceExisting) {
      throw const SshHostKeyVerificationException('主机密钥变更需要显式替换确认');
    }
    final replacement = SshHostKeyPolicy.newTrust(
      routeKey: routeKey,
      alias: alias,
      keyType: keyType,
      fingerprintSha256: fingerprint,
      source: SshHostKeySource.userConfirmed,
      now: now,
    );
    if (await _store.replaceTrusted(
      routeKey: routeKey,
      alias: alias,
      keyType: keyType,
      expectedFingerprint: existing.fingerprintSha256,
      replacement: replacement,
    )) {
      return true;
    }
    throw const SshHostKeyVerificationException('SSH 主机密钥已变化，替换确认未生效');
  }

  Future<void> _recordSuccessfulUse(SshHostKey key) async {
    try {
      if (await _store.touch(key)) return;
    } catch (error) {
      debugPrint('[SshHostKeyVerifier] 更新最近验证时间失败 '
          '(route=${key.routeKey}, alias=${key.alias}, type=${key.keyType}): $error');
    }
    throw const SshHostKeyVerificationException('SSH 主机信任在验证期间已撤销');
  }
}
