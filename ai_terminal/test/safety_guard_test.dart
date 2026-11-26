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

  group('SafetyGuard.check - 删除类命令需要确认', () {
    test('rm 单文件返回 warn', () {
      expect(SafetyGuard.check('rm /tmp/foo.txt'), SafetyLevel.warn);
    });

    test('rm -rf 非系统目录返回 warn', () {
      expect(SafetyGuard.check('rm -rf /tmp/cache'), SafetyLevel.warn);
    });

    test('sudo rm 返回 warn', () {
      expect(SafetyGuard.check('sudo rm /tmp/foo.txt'), SafetyLevel.warn);
    });

    test('unlink 返回 warn', () {
      expect(SafetyGuard.check('unlink /tmp/foo.txt'), SafetyLevel.warn);
    });

    test('shred 返回 warn', () {
      expect(SafetyGuard.check('shred -u /tmp/secret.txt'), SafetyLevel.warn);
    });

    test('find -delete 返回 warn', () {
      expect(
        SafetyGuard.check('find /tmp -name "*.log" -delete'),
        SafetyLevel.warn,
      );
    });

    test('truncate -s 0 返回 warn', () {
      expect(
        SafetyGuard.check('truncate -s 0 /var/log/app.log'),
        SafetyLevel.warn,
      );
    });

    test('rm -rf / 仍为 blocked（block 优先于 warn）', () {
      expect(SafetyGuard.check('rm -rf /'), SafetyLevel.blocked);
    });

    test('rm 命令的 getReason 返回删除风险说明', () {
      expect(SafetyGuard.getReason('rm /tmp/foo.txt'), contains('不可恢复'));
    });

    // 回归：Windows 本机终端是 PowerShell 5.1，写 cmdlet 曾被判成 safe，
    // 导致只读档在 Windows 上完全没有隔离（实测 Set-Content 直接写盘成功）。
    test('Set-Content 写文件返回 warn', () {
      expect(
        SafetyGuard.check(
            r'Set-Content -Path C:\Users\Administrator\Desktop\test.txt -Value 123'),
        SafetyLevel.warn,
      );
    });

    test('Out-File 返回 warn', () {
      expect(SafetyGuard.check(r'Get-Date | Out-File D:\tmp\a.txt'),
          SafetyLevel.warn);
    });

    test('New-Item / Remove-Item / Copy-Item 返回 warn', () {
      expect(SafetyGuard.check(r'New-Item -ItemType File -Path D:\tmp\a.txt'),
          SafetyLevel.warn);
      expect(SafetyGuard.check(r'Remove-Item D:\tmp\a.txt'), SafetyLevel.warn);
      expect(SafetyGuard.check(r'Copy-Item a.txt b.txt'), SafetyLevel.warn);
    });

    test('大小写与 & 调用运算符下的 cmdlet 仍为 warn', () {
      expect(SafetyGuard.check(r'set-content -path a.txt -value 1'),
          SafetyLevel.warn);
      expect(
          SafetyGuard.check(r'& Remove-Item D:\tmp\a.txt'), SafetyLevel.warn);
    });

    test('盘符重定向写文件返回 warn', () {
      expect(SafetyGuard.check(r'"abc" > D:\tmp\a.txt'), SafetyLevel.warn);
      expect(SafetyGuard.check(r'echo hi >> C:\tmp\a.log'), SafetyLevel.warn);
    });

    test('CMD 系写命令返回 warn', () {
      expect(SafetyGuard.check(r'del C:\Windows\Temp\a.tmp'), SafetyLevel.warn);
      expect(SafetyGuard.check(r'move a.txt b.txt'), SafetyLevel.warn);
      expect(SafetyGuard.check(r'mkdir D:\tmp\newdir'), SafetyLevel.warn);
    });

    test('Windows 磁盘级破坏命令返回 blocked', () {
      expect(SafetyGuard.check('Format-Volume -DriveLetter D'),
          SafetyLevel.blocked);
      expect(SafetyGuard.check('Clear-Disk -Number 1'), SafetyLevel.blocked);
    });

    test('只读 PowerShell 命令仍为 safe', () {
      expect(SafetyGuard.check(r'Get-ChildItem C:\Windows'), SafetyLevel.safe);
      expect(SafetyGuard.check(r'Test-Path D:\tmp\a.txt'), SafetyLevel.safe);
      expect(SafetyGuard.check(r'Get-Content D:\tmp\a.txt'), SafetyLevel.safe);
    });

    test('引号内的写 cmdlet 文本不误判（echo 只读）', () {
      expect(SafetyGuard.check('echo "Set-Content"'), SafetyLevel.safe);
    });

    // 回归：模型实际发出的命令是 powershell -Command "Set-Content ..." 外壳形式。
    // 第一版修复只锚定行首 cmdlet，被解释器外壳绕过，实测仍写盘成功。
    test('powershell -Command 外壳内的写 cmdlet 返回 warn', () {
      expect(
        SafetyGuard.check(
            "powershell -NoProfile -Command \"Set-Content -Path 'C:\\Users\\Administrator\\Desktop\\test2.txt' -Value 999\""),
        SafetyLevel.warn,
      );
      expect(
        SafetyGuard.check(
            r'powershell -NoProfile -Command Set-Content -Path D:\a.txt -Value 1'),
        SafetyLevel.warn,
      );
    });

    test('pwsh / cmd /c 外壳内的写操作同样返回 warn', () {
      expect(
        SafetyGuard.check(r'pwsh -NoProfile -Command "Remove-Item D:\a.txt"'),
        SafetyLevel.warn,
      );
      expect(
        SafetyGuard.check(r'cmd /c "del C:\Windows\Temp\a.tmp"'),
        SafetyLevel.warn,
      );
    });

    test('powershell 外壳内的只读命令仍为 safe', () {
      expect(
        SafetyGuard.check(
            "powershell -NoProfile -Command \"[Environment]::GetFolderPath('Desktop')\""),
        SafetyLevel.safe,
      );
      expect(
        SafetyGuard.check(
            "powershell -NoProfile -Command \"Get-Item 'C:\\a.txt' | Select-Object Length\""),
        SafetyLevel.safe,
      );
    });
  });

  group('SafetyGuard.check - POSIX 通用写命令', () {
    test('cp / mv 复制移动文件返回 warn', () {
      expect(SafetyGuard.check('cp a.txt b.txt'), SafetyLevel.warn);
      expect(SafetyGuard.check('mv /tmp/a /tmp/b'), SafetyLevel.warn);
      expect(SafetyGuard.check('sudo cp a.txt /srv/b.txt'), SafetyLevel.warn);
    });

    test('sed -i 原地编辑返回 warn，纯管道 sed 不误判', () {
      expect(SafetyGuard.check("sed -i 's/a/b/' app.conf"), SafetyLevel.warn);
      expect(SafetyGuard.check("sed -Ei 's/a/b/' app.conf"), SafetyLevel.warn);
      expect(SafetyGuard.check("sed --in-place 's/a/b/' app.conf"),
          SafetyLevel.warn);
      expect(SafetyGuard.check("sed 's/a/b/' app.conf"), SafetyLevel.safe);
    });

    test('sed -i 在参数任意位置都识别（选项顺序不应绕过只读档）', () {
      expect(
          SafetyGuard.check("sed -E -i 's/a/b/' app.conf"), SafetyLevel.warn);
      expect(
          SafetyGuard.check("sed -n -i 's/a/b/p' app.conf"), SafetyLevel.warn);
      expect(
          SafetyGuard.check("sed -e 's/a/b/' -i app.conf"), SafetyLevel.warn);
      expect(SafetyGuard.check("sudo -E sed -i 's/a/b/' app.conf"),
          SafetyLevel.warn);
      expect(
          SafetyGuard.check("sed -i.bak 's/a/b/' app.conf"), SafetyLevel.warn);
      // 只有脚本/文件名里出现字母 i，不许误判
      expect(SafetyGuard.check("sed -e 's/i/x/' input.txt"), SafetyLevel.safe);
    });

    test('sed 不在行首时也不能绕过只读档', () {
      expect(SafetyGuard.check("sudo -u root sed -i 's/a/b/' app.conf"),
          SafetyLevel.warn);
      expect(SafetyGuard.check("LC_ALL=C sed -i 's/a/b/' app.conf"),
          SafetyLevel.warn);
      expect(SafetyGuard.check("env X=1 sed -i 's/a/b/' app.conf"),
          SafetyLevel.warn);
      expect(SafetyGuard.check("bash -c \"sed -i 's/a/b/' app.conf\""),
          SafetyLevel.warn);
      expect(SafetyGuard.check("xargs sed -i 's/a/b/'"), SafetyLevel.warn);
    });

    test('tee 管道写文件返回 warn', () {
      expect(
          SafetyGuard.check('echo hi | sudo tee /etc/hosts'), SafetyLevel.warn);
      expect(SafetyGuard.check('echo hi | tee -a app.log'), SafetyLevel.warn);
    });

    test('chmod / chown / chgrp / touch / ln 返回 warn', () {
      expect(SafetyGuard.check('chmod 644 app.conf'), SafetyLevel.warn);
      expect(
          SafetyGuard.check('sudo chown root:root app.conf'), SafetyLevel.warn);
      expect(SafetyGuard.check('chgrp www-data app.conf'), SafetyLevel.warn);
      expect(SafetyGuard.check('touch app.lock'), SafetyLevel.warn);
      expect(SafetyGuard.check('ln -s /srv/app current'), SafetyLevel.warn);
    });

    test('dd 写普通文件与任意 truncate 返回 warn', () {
      expect(SafetyGuard.check('dd if=/dev/zero of=/tmp/fill bs=1M count=1'),
          SafetyLevel.warn);
      expect(
          SafetyGuard.check('truncate -s 1M /tmp/app.log'), SafetyLevel.warn);
    });
  });

  group('SafetyGuard.check - 低风险与修改型分类', () {
    test('curl http:// 返回 info', () {
      expect(
        SafetyGuard.check('curl http://example.com'),
        SafetyLevel.info,
      );
    });

    test('修改型低风险模式已收紧为 warn', () {
      expect(
        SafetyGuard.check('git clone https://github.com/repo.git'),
        SafetyLevel.warn,
      );
      expect(
        SafetyGuard.check('systemctl restart nginx'),
        SafetyLevel.warn,
      );
      expect(SafetyGuard.check('npm install -g pm2'), SafetyLevel.warn);
      expect(SafetyGuard.check('pip install requests'), SafetyLevel.warn);
      expect(SafetyGuard.check('brew install jq'), SafetyLevel.warn);
      expect(SafetyGuard.check('sudo apt update'), SafetyLevel.warn);
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

    test('ls || systemctl restart nginx 返回 warn', () {
      expect(
        SafetyGuard.check('ls || systemctl restart nginx'),
        SafetyLevel.warn,
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
