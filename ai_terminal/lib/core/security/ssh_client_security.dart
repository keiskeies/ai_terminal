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
}
