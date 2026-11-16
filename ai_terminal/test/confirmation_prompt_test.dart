import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/pty_output_detector.dart';

/// WP5（O3）：确认类提示拆分 + 尾部锚定匹配 + 应答去重 + 保守自动应答规则。
///
/// 锁住三条安全边界：
/// 1. 密码类提示（Password:/Enter passphrase）**永不**走自由文本桥（R7），
///    无论调用方是否声明桥接都按 interactivePrompt 中断。
/// 2. 确认类匹配只看缓冲尾部（R8）：正文里出现 `(yes/no)`/`[Y/n]` 不算提示。
/// 3. 自动应答只在默认值明确安全时给答案（[Y/n]→Y、Press ENTER→回车），
///    其余一律 null 交回 UI。
void main() {
  group('密码/确认拆分', () {
    test('Password: 不命中确认匹配，且声明桥接仍中断（R7）', () {
      const buffer = 'ssh deploy@10.0.0.5\r\nPassword: ';
      expect(PtyOutputDetector.confirmationPromptMatch(buffer), isNull);
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
        confirmationPromptWillBeBridged: true,
      );
      expect(diag, isNotNull);
      expect(diag!.kind, CommandFailureKind.interactivePrompt);
    });

    test('Enter passphrase 不命中确认匹配，桥接也中断', () {
      const buffer = 'ssh-keygen -t ed25519\r\nEnter passphrase for key: ';
      expect(PtyOutputDetector.confirmationPromptMatch(buffer), isNull);
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
        confirmationPromptWillBeBridged: true,
      );
      expect(diag!.kind, CommandFailureKind.interactivePrompt);
    });

    test('ssh yes/no 确认：未桥接中断，声明桥接则放行', () {
      const buffer =
          'Are you sure you want to continue connecting (yes/no/[fingerprint])? ';
      expect(PtyOutputDetector.confirmationPromptMatch(buffer), isNotNull);
      final interrupted = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
      );
      expect(interrupted!.kind, CommandFailureKind.interactivePrompt);
      final bridged = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
        confirmationPromptWillBeBridged: true,
      );
      expect(bridged, isNull);
    });

    test('sudo 提示不受确认桥接开关影响（仍走 sudo 应答路径）', () {
      const buffer = '[sudo] password for cjm: ';
      expect(PtyOutputDetector.confirmationPromptMatch(buffer), isNull);
      final diag = PtyOutputDetector.detect(
        buffer: buffer,
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
        confirmationPromptWillBeBridged: true,
      );
      expect(diag!.kind, CommandFailureKind.interactivePrompt);
    });
  });

  group('尾部锚定确认匹配（R8）', () {
    test('常见确认提示尾部形态都能命中', () {
      const tails = [
        'Do you want to continue? [Y/n] ',
        'Continue? [Y/n]: ', // PowerShell Read-Host 追加 ": "
        'Overwrite? [y/N] ',
        'Proceed with installation? [Y/n]',
        'Continue? ',
        'Press ENTER to continue',
        'Are you sure you want to continue connecting (yes/no)? ',
        '(yes/no/[fingerprint])? ',
      ];
      for (final tail in tails) {
        expect(
          PtyOutputDetector.confirmationPromptMatch('cmd echo\r\n$tail'),
          isNotNull,
          reason: '尾部「$tail」应命中确认提示',
        );
      }
    });

    test('正文里的确认字样不算提示（只看尾部）', () {
      const buffers = [
        'Are you sure you want to continue connecting (yes/no)? yes\r\nfingerprint saved\r\n',
        'install [Y/n] defaults\r\nreading package list... ',
        'manual says: press ENTER to continue\r\n\$ ',
      ];
      for (final b in buffers) {
        expect(PtyOutputDetector.confirmationPromptMatch(b), isNull,
            reason: '「$b」的尾部不是确认提示');
      }
    });

    test('新增尾部形态未桥接时也中断（不再干等超时）', () {
      final diag = PtyOutputDetector.detect(
        buffer: 'apt install foo\r\nDo you want to continue? [Y/n] ',
        marker: 'EXITCODE_1:',
        elapsedMs: 500,
        isWindows: false,
      );
      expect(diag!.kind, CommandFailureKind.interactivePrompt);
    });

    test('confirmationPromptText 取尾部行并剥 ANSI', () {
      expect(
        PtyOutputDetector.confirmationPromptText(
            'cmd echo\r\nAre you sure you want to continue connecting (yes/no)? '),
        'Are you sure you want to continue connecting (yes/no)?',
      );
      expect(
        PtyOutputDetector.confirmationPromptText(
            '\x1B[32mContinue? [Y/n]\x1B[0m: '),
        'Continue? [Y/n]:',
      );
    });
  });

  group('ConfirmationPromptResponder 下标去重', () {
    test('同一提示的增量 chunk 只应答一次', () {
      final r = ConfirmationPromptResponder();
      expect(r.shouldAnswer('echo hi\r\nContinue? [Y/n]'), isTrue);
      expect(r.shouldAnswer('echo hi\r\nContinue? [Y/n] '), isFalse);
      expect(r.shouldAnswer('echo hi\r\nContinue? [Y/n]: '), isFalse);
    });

    test('命令链里的下一个确认提示（下标前进）再次应答', () {
      final r = ConfirmationPromptResponder();
      expect(r.shouldAnswer('echo hi\r\nContinue? [Y/n] '), isTrue);
      expect(
        r.shouldAnswer('echo hi\r\nContinue? [Y/n] yes\r\nOverwrite? [y/N] '),
        isTrue,
      );
      expect(
        r.shouldAnswer('echo hi\r\nContinue? [Y/n] yes\r\nOverwrite? [y/N] '),
        isFalse,
      );
    });

    test('缓冲尾部截断导致下标前移时重置游标', () {
      final r = ConfirmationPromptResponder();
      final big = '${'x' * 100}Continue? [Y/n] ';
      expect(r.shouldAnswer(big), isTrue);
      expect(r.shouldAnswer(big), isFalse);
      // 截断后旧游标越界：必须重置，否则新缓冲里的提示永远答不上
      const small = 'Continue? [Y/n] ';
      expect(r.shouldAnswer(small), isTrue);
    });

    test('无提示时不应答', () {
      final r = ConfirmationPromptResponder();
      expect(r.shouldAnswer('reading package list... '), isFalse);
      expect(r.shouldAnswer('Password: '), isFalse);
    });
  });

  group('保守自动应答规则', () {
    test('[Y/n]（默认 Yes）→ Y', () {
      expect(PtyOutputDetector.confirmationAutoAnswer(
          'Do you want to continue? [Y/n] '), 'Y');
      expect(PtyOutputDetector.confirmationAutoAnswer('Continue? [Y/n]: '), 'Y');
    });

    test('Press ENTER → 空串（直接回车），大小写不敏感', () {
      expect(PtyOutputDetector.confirmationAutoAnswer('Press ENTER to continue'), '');
      expect(PtyOutputDetector.confirmationAutoAnswer('press enter or type a value'), '');
    });

    test('无安全默认值的提示一律 null（交回 UI）', () {
      expect(PtyOutputDetector.confirmationAutoAnswer('Overwrite? [y/N] '), isNull);
      expect(PtyOutputDetector.confirmationAutoAnswer('(yes/no)? '), isNull);
      expect(PtyOutputDetector.confirmationAutoAnswer('Continue? '), isNull);
    });

    test('密码类提示永不自动应答（R7），即使带 [Y/n] 字样', () {
      expect(PtyOutputDetector.confirmationAutoAnswer('Password: '), isNull);
      expect(PtyOutputDetector.confirmationAutoAnswer('Enter passphrase'), isNull);
      expect(PtyOutputDetector.confirmationAutoAnswer('输入密码：'), isNull);
      expect(PtyOutputDetector.confirmationAutoAnswer('[Y/n] Password:'), isNull);
    });
  });
}