import 'package:dartssh2/dartssh2.dart';

/// SSH 传输加密算法偏好。
///
/// dartssh2 的 AES-GCM 是纯 Dart 实现：在本机实测 SFTP 只有约 1.5MB/s，
/// 而 ChaCha20-Poly1305 约 26MB/s、AES-CTR 约 18–20MB/s。默认算法把
/// AES-GCM 排在最前，导致大文件传输被 CPU 卡在 1MB/s 附近，看起来像网络慢。
///
/// 排序原则：ChaCha20-Poly1305（AEAD）优先；AES-CTR 作为高速后备，
/// 配合默认的 HMAC-SHA256 Encrypt-then-MAC；AES-GCM 保留给只支持它的
/// 老服务器；CBC 仅作为最后兜底（CVE-2008-5161，默认不优先）。
const SSHAlgorithms kFastSshAlgorithms = SSHAlgorithms(
  cipher: [
    SSHCipherType.chacha20poly1305,
    SSHCipherType.aes128ctr,
    SSHCipherType.aes256ctr,
    SSHCipherType.aes128gcm,
    SSHCipherType.aes256gcm,
    SSHCipherType.aes128cbc,
    SSHCipherType.aes256cbc,
  ],
);
