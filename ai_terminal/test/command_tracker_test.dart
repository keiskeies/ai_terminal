import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/command_tracker.dart';

void main() {
  group('extract（屏幕行 → 命令的三道闸门）', () {
    test('bash 提示符 + 命令 → 命令', () {
      expect(CommandTracker.extract(r'user@web1:/srv$ nginx -t'), 'nginx -t');
    });

    test('PowerShell 提示符', () {
      expect(
        CommandTracker.extract(r'PS C:\inetpub> Get-Service'),
        'Get-Service',
      );
    });

    test('闸门 1：没有提示符 → 不记（全屏程序里的正文行）', () {
      expect(CommandTracker.extract('func main() {'), isNull);
      expect(CommandTracker.extract('    return err'), isNull);
    });

    test('闸门 2：提示符后为空 → 不记（关回显的密码输入）', () {
      expect(CommandTracker.extract(r'user@web1:/srv$'), isNull);
      expect(CommandTracker.extract(r'root@web1:/# '), isNull);
    });

    test('闸门 3：提示符后不像命令 → 不记', () {
      expect(CommandTracker.extract('你好 世界'), isNull);
      expect(CommandTracker.extract(r'user@web1:~$ 你好 世界'), isNull);
    });

    test('空白行 → 不记', () {
      expect(CommandTracker.extract(''), isNull);
      expect(CommandTracker.extract('   '), isNull);
    });
  });

  group('onInput / onOutput 协同', () {
    test('没有回车 → 不记', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onOutput('user@web1:~\$ ');
      t.onInput('ls -l', currentInputLine: () => r'user@web1:~$ ls -l');
      expect(captured, isEmpty);
    });

    test('回车 → 记一条', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onOutput('user@web1:~\$ ');
      t.onInput('\r', currentInputLine: () => r'user@web1:~$ ls -l');
      expect(captured, ['ls -l']);
    });

    test('连续重复的同一命令只记一次', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      for (var i = 0; i < 3; i++) {
        t.onInput('\r', currentInputLine: () => r'user@web1:~$ ls -l');
      }
      t.onInput('\r', currentInputLine: () => r'user@web1:~$ ls -a');
      expect(captured, ['ls -l', 'ls -a']);
    });

    test('中间插入别的命令后，重复命令可以再记（不是全局去重）', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onInput('\r', currentInputLine: () => r'user@web1:~$ ls -l');
      t.onInput('\r', currentInputLine: () => r'user@web1:~$ pwd');
      t.onInput('\r', currentInputLine: () => r'user@web1:~$ ls -l');
      expect(captured, ['ls -l', 'pwd', 'ls -l']);
    });

    test('回车 + 可见文本同批到达也只记一次', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onInput('ls\r', currentInputLine: () => r'user@web1:~$ ls');
      expect(captured.length, 1);
    });

    test('sudo 提示之后那次回车不记（密码应答）', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onOutput('[sudo] password for cjm: ');
      // 用户敲密码：shell 关回显，屏幕上提示符后面什么都没有
      t.onInput('\r', currentInputLine: () => '[sudo] password for cjm: ');
      expect(captured, isEmpty);
    });

    test('密码提示锁只吃掉一次输入，之后恢复正常捕获', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onOutput('Enter passphrase for key ~/.ssh/id_rsa: ');
      t.onInput('hunter2\r', currentInputLine: () => 'passphrase: hunter2');
      t.onOutput('user@web1:~\$ ');
      t.onInput('\r', currentInputLine: () => r'user@web1:~$ id');
      expect(captured, ['id']);
    });

    test('中文密码提示同样锁住', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onOutput('请输入密码：');
      t.onInput('p@ss\r', currentInputLine: () => '请输入密码：p@ss');
      expect(captured, isEmpty);
    });

    test('即便回显没关（屏上有明文），锁在时也不记', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onOutput('Password: ');
      t.onInput('\r', currentInputLine: () => 'Password: hunter2');
      expect(captured, isEmpty);
    });

    test('正文里的 [sudo] 不在尾部 → 不触发锁（R8 不用裸子串）', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onOutput('[sudo] password for cjm: \nuser@web1:~\$ ');
      t.onInput('\r', currentInputLine: () => r'user@web1:~$ whoami');
      expect(captured, ['whoami']);
    });

    test('颜色码不影响提示语判定', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onOutput('\x1B[1;32muser@web1\x1B[0m:~\$ ');
      t.onInput('\r', currentInputLine: () => r'user@web1:~$ df -h');
      expect(captured, ['df -h']);
    });

    test('方向键（ESC [ A）不算提交', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onInput('\x1B[A', currentInputLine: () => r'user@web1:~$ ls -l');
      expect(captured, isEmpty);
    });

    test('reset 清掉密码锁与输出缓冲', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onOutput('[sudo] password for cjm: ');
      t.reset();
      t.onInput('\r', currentInputLine: () => r'user@web1:~$ id');
      expect(captured, ['id']);
    });

    test('超长输出后仍只看尾部（缓冲有上限，不留全量）', () {
      final captured = <String>[];
      final t = CommandTracker(onCommand: captured.add);
      t.onOutput('x' * 40000);
      t.onOutput('\r\n[sudo] password for cjm: ');
      t.onInput('secret\r',
          currentInputLine: () => '[sudo] password for cjm: secret');
      expect(captured, isEmpty);
    });
  });
}
