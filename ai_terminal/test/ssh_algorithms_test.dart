import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/ssh_algorithms.dart';

void main() {
  test('SSH 加密偏好把 ChaCha20-Poly1305 排在 AES-GCM 前', () {
    final ciphers = kFastSshAlgorithms.cipher;
    final chacha = ciphers.indexOf(SSHCipherType.chacha20poly1305);
    final aesCtr = ciphers.indexOf(SSHCipherType.aes256ctr);
    final aesGcm = ciphers.indexOf(SSHCipherType.aes256gcm);

    expect(chacha, 0, reason: '纯 Dart AES-GCM 实测约 1.5MB/s，必须排在后面');
    expect(aesCtr, lessThan(aesGcm), reason: 'AES-CTR 作为高速后备');
    expect(ciphers.last, SSHCipherType.aes256cbc,
        reason: 'CBC 只作为老服务器兜底');
  });
}
