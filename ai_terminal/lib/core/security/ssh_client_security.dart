import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'ssh_host_key_store.dart';
import 'ssh_host_key_verifier.dart';

final Expando<bool> _verifiedClients = Expando<bool>('verifiedSshClients');

class SshClientSecurity {
  static SshHostKeyVerifier? _verifierOverride;

  static SshHostKeyVerifier get verifier =>
      _verifierOverride ??= SshHostKeyVerifier(store: SshHostKeyStore());

  @visibleForTesting
  static set verifierOverride(SshHostKeyVerifier? verifier) {
    _verifierOverride = verifier;
  }

  static void markVerified(SSHClient client) {
    _verifiedClients[client] = true;
  }

  static void clearVerified(SSHClient client) {
    _verifiedClients[client] = null;
  }

  static void requireVerified(SSHClient client) {
    if (_verifiedClients[client] != true) {
      throw StateError('SSH 连接尚未完成主机身份验证，不能复用');
    }
  }

  /// 剥掉 dartssh2 的包装，找回建连失败的真实原因。
  ///
  /// [onVerifyHostKey] 抛出的异常不是 `SSHError`，会被 transport 包成
  /// `SSHInternalError`，再由 SSHClient 包成
  /// `SSHAuthAbortError(Connection closed before authentication)`。原始异常只
  /// 剩 `.reason` 里的一层，直接 `toString()` 得到的是「认证」字样——用户和日志
  /// 都会去查密码，而真正的原因是主机密钥被拒绝/不匹配。
  static Object unwrapConnectionFailure(Object error) {
    Object current = error;
    for (var depth = 0; depth < 5; depth++) {
      final next = current is SSHAuthAbortError
          ? current.reason
          : current is SSHInternalError
              ? current.error
              : null;
      if (next == null || identical(next, current)) break;
      current = next;
    }
    return current;
  }
}
