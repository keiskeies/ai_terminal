import 'package:encrypt/encrypt.dart';
import 'package:flutter_test/flutter_test.dart';

/// encrypt 5.0.3 仍声明 pointycastle ^3，但项目通过 dependency_overrides
/// 使用 pointycastle 4（dartssh2 3.x 要求）。本测试防止该组合在升级后静默失效。
void main() {
  test('encrypt + pointycastle 4 AES 往返一致', () {
    final key = Key.fromUtf8('0123456789abcdef0123456789abcdef');
    final iv = IV.fromSecureRandom(16);
    final encrypter = Encrypter(AES(key));

    const plaintext = 'hello 中文 credentials';
    final encrypted = encrypter.encrypt(plaintext, iv: iv);

    expect(encrypter.decrypt(encrypted, iv: iv), plaintext);
    expect(encrypted.base64, isNotEmpty);
  });
}
