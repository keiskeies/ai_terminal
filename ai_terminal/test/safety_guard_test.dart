import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/safety_guard.dart';

void main() {
  group('SafetyGuard.check - safe 命令', () {
    test('ls 返回 safe', () {
      expect(SafetyGuard.check('ls'), SafetyLevel.safe);
    });

    test('cat 文件 返回 safe', () {
      expect(SafetyGuard.check('cat file.txt'), SafetyLevel.safe);
    });

    test('grep 递归搜索 返回 safe', () {
      expect(SafetyGuard.check('grep -r pattern .'), SafetyLevel.safe);
    });

    test('ps aux 返回 safe', () {
      expect(SafetyGuard.check('ps aux'), SafetyLevel.safe);
    });
  });

  group('SafetyGuard.check - blocked 命令', () {
    test('rm -rf / 返回 blocked', () {
      expect(SafetyGuard.check('rm -rf /'), SafetyLevel.blocked);
    });

    test('dd if=/dev/zero of=/dev/sda 返回 blocked', () {
      expect(
        SafetyGuard.check('dd if=/dev/zero of=/dev/sda'),
        SafetyLevel.blocked,
      );
    });

    test('mkfs.ext4 返回 blocked', () {
      expect(
        SafetyGuard.check('mkfs.ext4 /dev/sda1'),
        SafetyLevel.blocked,
      );
    });

    test('fork 炸弹 返回 blocked', () {
      expect(SafetyGuard.check(':(){ :|:& };:'), SafetyLevel.blocked);
    });

    test('crontab -r 返回 blocked', () {
      expect(SafetyGuard.check('crontab -r'), SafetyLevel.blocked);
    });

    test('systemctl mask 返回 blocked', () {
      expect(SafetyGuard.check('systemctl mask sshd'), SafetyLevel.blocked);
    });

    test('iptables -P INPUT DROP 返回 blocked', () {
      expect(
        SafetyGuard.check('iptables -P INPUT DROP'),
        SafetyLevel.blocked,
      );
    });

    test('pkill -9 返回 blocked', () {
      expect(SafetyGuard.check('pkill -9 nginx'), SafetyLevel.blocked);
    });

    test('kill -9 -1 返回 blocked', () {
      expect(SafetyGuard.check('kill -9 -1'), SafetyLevel.blocked);
    });
  });

  group('SafetyGuard.check - warn 命令', () {
    test('sudo apt install 返回 warn', () {
      expect(
        SafetyGuard.check('sudo apt install nginx'),
        SafetyLevel.warn,
      );
    });

    test('sudo yum remove 返回 warn', () {
      expect(
        SafetyGuard.check('sudo yum remove nginx'),
        SafetyLevel.warn,
      );
    });

    test('systemctl stop sshd 返回 warn', () {
      expect(SafetyGuard.check('systemctl stop sshd'), SafetyLevel.warn);
    });

    test('fdisk /dev/sda 返回 warn', () {
      expect(SafetyGuard.check('fdisk /dev/sda'), SafetyLevel.warn);
    });
  });

  group('SafetyGuard.check - info 命令', () {
    test('curl http:// 返回 info', () {
      expect(
        SafetyGuard.check('curl http://example.com'),
        SafetyLevel.info,
      );
    });

    test('git clone 返回 info', () {
      expect(
        SafetyGuard.check('git clone https://github.com/repo.git'),
        SafetyLevel.info,
      );
    });

    test('systemctl restart 返回 info', () {
      expect(
        SafetyGuard.check('systemctl restart nginx'),
        SafetyLevel.info,
      );
    });
  });

  group('SafetyGuard - 绕过防护', () {
    test('多空格 rm  -rf  / 仍被拦截', () {
      expect(SafetyGuard.check('rm  -rf  /'), SafetyLevel.blocked);
    });

    test('引号包裹 "rm" -rf / 仍被拦截', () {
      expect(SafetyGuard.check('"rm" -rf /'), SafetyLevel.blocked);
    });

    test('反斜杠 r\\m -rf / 仍被拦截', () {
      expect(SafetyGuard.check(r'r\m -rf /'), SafetyLevel.blocked);
    });
  });

  group('SafetyGuard - 链式命令拆分', () {
    test('ls && rm -rf / 返回 blocked（取最高危险等级）', () {
      expect(SafetyGuard.check('ls && rm -rf /'), SafetyLevel.blocked);
    });

    test('ls && cat file 返回 safe（全部子命令安全）', () {
      expect(SafetyGuard.check('ls && cat file'), SafetyLevel.safe);
    });

    test('ls || systemctl restart nginx 返回 info', () {
      expect(
        SafetyGuard.check('ls || systemctl restart nginx'),
        SafetyLevel.info,
      );
    });

    test('ls | grep foo 返回 safe', () {
      expect(SafetyGuard.check('ls | grep foo'), SafetyLevel.safe);
    });
  });

  group('SafetyGuard.getReason', () {
    test('blocked 命令返回风险说明', () {
      final reason = SafetyGuard.getReason('rm -rf /');
      expect(reason, isNotNull);
      expect(reason, contains('递归删除'));
    });

    test('dd 写入块设备返回风险说明', () {
      final reason = SafetyGuard.getReason('dd if=/dev/zero of=/dev/sda');
      expect(reason, isNotNull);
      expect(reason, contains('块设备'));
    });

    test('warn 命令返回风险说明', () {
      final reason = SafetyGuard.getReason('sudo apt install nginx');
      expect(reason, isNotNull);
      expect(reason, contains('软件包'));
    });

    test('systemctl stop sshd 返回风险说明', () {
      final reason = SafetyGuard.getReason('systemctl stop sshd');
      expect(reason, isNotNull);
      expect(reason, contains('SSH'));
    });

    test('safe 命令返回 null', () {
      expect(SafetyGuard.getReason('ls'), isNull);
    });

    test('info 命令返回 null（info 规则无 reason）', () {
      expect(SafetyGuard.getReason('curl http://example.com'), isNull);
    });

    test('绕过命令的 getReason 仍返回正确说明', () {
      final reason = SafetyGuard.getReason('rm  -rf  /');
      expect(reason, isNotNull);
      expect(reason, contains('递归删除'));
    });
  });

  group('SafetyGuard.requireConfirm', () {
    test('safe 不需要确认', () {
      expect(SafetyGuard.requireConfirm(SafetyLevel.safe), isFalse);
    });

    test('info 不需要确认', () {
      expect(SafetyGuard.requireConfirm(SafetyLevel.info), isFalse);
    });

    test('warn 需要确认', () {
      expect(SafetyGuard.requireConfirm(SafetyLevel.warn), isTrue);
    });

    test('blocked 需要确认', () {
      expect(SafetyGuard.requireConfirm(SafetyLevel.blocked), isTrue);
    });
  });

  group('SafetyGuard.getTip', () {
    test('safe 提示', () {
      expect(SafetyGuard.getTip(SafetyLevel.safe), '安全命令');
    });

    test('blocked 提示', () {
      expect(SafetyGuard.getTip(SafetyLevel.blocked), '高危操作，已被安全策略拦截');
    });
  });
}
