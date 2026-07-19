import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/command_heuristics.dart';

void main() {
  group('isQueryCommand', () {
    test('ls 返回 true', () {
      expect(isQueryCommand('ls'), isTrue);
    });

    test('cat 文件 返回 true', () {
      expect(isQueryCommand('cat file.txt'), isTrue);
    });

    test('ps aux 返回 true', () {
      expect(isQueryCommand('ps aux'), isTrue);
    });

    test('systemctl status 返回 true', () {
      expect(isQueryCommand('systemctl status nginx'), isTrue);
    });

    test('systemctl list 返回 true', () {
      expect(isQueryCommand('systemctl list-units'), isTrue);
    });

    test('grep 搜索 返回 true', () {
      expect(isQueryCommand('grep -r pattern .'), isTrue);
    });

    test('docker ps 返回 true', () {
      expect(isQueryCommand('docker ps'), isTrue);
    });

    test('journalctl 返回 true', () {
      expect(isQueryCommand('journalctl -u nginx'), isTrue);
    });

    test('sudo apt install 返回 false', () {
      expect(isQueryCommand('sudo apt install nginx'), isFalse);
    });

    test('rm -rf / 返回 false', () {
      expect(isQueryCommand('rm -rf /'), isFalse);
    });

    test('systemctl restart 返回 false（非只读子命令）', () {
      expect(isQueryCommand('systemctl restart nginx'), isFalse);
    });

    test('大小写不敏感', () {
      expect(isQueryCommand('LS -LA'), isTrue);
    });

    test('前后空格被去除', () {
      expect(isQueryCommand('  ls -la  '), isTrue);
    });

    // 新增：硬件/资源查看类只读命令
    test('lscpu 返回 true', () {
      expect(isQueryCommand('lscpu'), isTrue);
    });

    test('lsblk 返回 true', () {
      expect(isQueryCommand('lsblk'), isTrue);
    });

    test('lspci 返回 true', () {
      expect(isQueryCommand('lspci -vv'), isTrue);
    });

    test('lsusb 返回 true', () {
      expect(isQueryCommand('lsusb'), isTrue);
    });

    test('sar 返回 true', () {
      expect(isQueryCommand('sar -u 1 3'), isTrue);
    });

    test('iotop 返回 true', () {
      expect(isQueryCommand('iotop -n 1'), isTrue);
    });

    // 新增：systemctl 只读子命令
    test('systemctl show 返回 true', () {
      expect(isQueryCommand('systemctl show nginx'), isTrue);
    });

    test('systemctl is-active 返回 true', () {
      expect(isQueryCommand('systemctl is-active nginx'), isTrue);
    });

    test('systemctl is-enabled 返回 true', () {
      expect(isQueryCommand('systemctl is-enabled nginx'), isTrue);
    });

    // 新增：docker 只读子命令
    test('docker stats 返回 true', () {
      expect(isQueryCommand('docker stats --no-stream'), isTrue);
    });

    test('docker history 返回 true', () {
      expect(isQueryCommand('docker history nginx'), isTrue);
    });

    test('docker version 返回 true', () {
      expect(isQueryCommand('docker version'), isTrue);
    });

    // 新增：git 只读子命令
    test('git status 返回 true', () {
      expect(isQueryCommand('git status'), isTrue);
    });

    test('git log 返回 true', () {
      expect(isQueryCommand('git log --oneline -10'), isTrue);
    });

    test('git diff 返回 true', () {
      expect(isQueryCommand('git diff HEAD~1'), isTrue);
    });

    // 新增：网络/防火墙只读
    test('iptables -L 返回 true', () {
      expect(isQueryCommand('iptables -L -n -v'), isTrue);
    });

    test('ufw status 返回 true', () {
      expect(isQueryCommand('ufw status verbose'), isTrue);
    });

    test('crontab -l 返回 true', () {
      expect(isQueryCommand('crontab -l'), isTrue);
    });

    // 修复验证：交互式命令应返回 false
    test('top 返回 false（交互式）', () {
      expect(isQueryCommand('top'), isFalse);
    });

    test('htop 返回 false（交互式）', () {
      expect(isQueryCommand('htop'), isFalse);
    });

    test('less 文件 返回 false（交互式分页器）', () {
      expect(isQueryCommand('less file.txt'), isFalse);
    });

    test('more 文件 返回 false（交互式分页器）', () {
      expect(isQueryCommand('more file.txt'), isFalse);
    });

    test('tail -f 日志 返回 false（持续跟踪）', () {
      expect(isQueryCommand('tail -f /var/log/syslog'), isFalse);
    });

    test('tail --follow 日志 返回 false（持续跟踪，长选项形式）', () {
      expect(isQueryCommand('tail --follow=name /var/log/syslog'), isFalse);
    });

    test('tail --follow 日志 返回 false（持续跟踪，无参长选项）', () {
      expect(isQueryCommand('tail --follow /var/log/syslog'), isFalse);
    });

    test('tailf 日志 返回 false（持续跟踪）', () {
      expect(isQueryCommand('tailf /var/log/syslog'), isFalse);
    });

    test('man ls 返回 false（交互式手册）', () {
      expect(isQueryCommand('man ls'), isFalse);
    });

    test('vim file 返回 false（交互式编辑器）', () {
      expect(isQueryCommand('vim file.txt'), isFalse);
    });

    test('top -n 1 -b 返回 false（top 即使带参数也排除，agent 应用 ps 替代）', () {
      expect(isQueryCommand('top -n 1 -b'), isFalse);
    });

    // 普通 tail 仍应返回 true（非跟踪模式）
    test('tail -100 file 返回 true', () {
      expect(isQueryCommand('tail -100 /var/log/syslog'), isTrue);
    });
  });

  group('getCommandTimeout', () {
    test('apt install 返回 10 分钟', () {
      expect(getCommandTimeout('apt install nginx'), const Duration(minutes: 10));
    });

    test('apt-get install 返回 10 分钟', () {
      expect(
        getCommandTimeout('apt-get install nginx'),
        const Duration(minutes: 10),
      );
    });

    test('yum install 返回 10 分钟', () {
      expect(
        getCommandTimeout('yum install nginx'),
        const Duration(minutes: 10),
      );
    });

    test('npm install 返回 10 分钟', () {
      expect(
        getCommandTimeout('npm install'),
        const Duration(minutes: 10),
      );
    });

    test('make 返回 10 分钟', () {
      expect(getCommandTimeout('make'), const Duration(minutes: 10));
    });

    test('systemctl status 返回 3 分钟', () {
      expect(
        getCommandTimeout('systemctl status nginx'),
        const Duration(minutes: 3),
      );
    });

    test('systemctl restart 返回 3 分钟', () {
      expect(
        getCommandTimeout('systemctl restart nginx'),
        const Duration(minutes: 3),
      );
    });

    test('ps aux 返回 3 分钟', () {
      expect(getCommandTimeout('ps aux'), const Duration(minutes: 3));
    });

    test('journalctl 返回 3 分钟', () {
      expect(getCommandTimeout('journalctl -u nginx'), const Duration(minutes: 3));
    });

    test('curl 返回 3 分钟', () {
      expect(
        getCommandTimeout('curl http://example.com'),
        const Duration(minutes: 3),
      );
    });

    test('git clone 返回 3 分钟', () {
      expect(
        getCommandTimeout('git clone https://github.com/repo.git'),
        const Duration(minutes: 3),
      );
    });

    test('ls 返回 60 秒（默认）', () {
      expect(getCommandTimeout('ls'), const Duration(seconds: 60));
    });

    test('echo 返回 60 秒（默认）', () {
      expect(getCommandTimeout('echo hello'), const Duration(seconds: 60));
    });

    test('cat 返回 60 秒（默认）', () {
      expect(getCommandTimeout('cat file.txt'), const Duration(seconds: 60));
    });

    test('大小写不敏感', () {
      expect(
        getCommandTimeout('APT INSTALL nginx'),
        const Duration(minutes: 10),
      );
    });

    test('前后空格被去除', () {
      expect(
        getCommandTimeout('  apt install nginx  '),
        const Duration(minutes: 10),
      );
    });
  });

  group('isDescriptiveText', () {
    test('中文占比过高的文本返回 true', () {
      expect(isDescriptiveText('这是一个中文说明文字'), isTrue);
    });

    test('以"请"开头的文本返回 true', () {
      expect(isDescriptiveText('请输入命令'), isTrue);
    });

    test('以"可以"开头的文本返回 true', () {
      expect(isDescriptiveText('可以使用以下命令'), isTrue);
    });

    test('以"命令"开头的文本返回 true', () {
      expect(isDescriptiveText('命令说明如下'), isTrue);
    });

    test('以"步骤"开头的文本返回 true', () {
      expect(isDescriptiveText('步骤一：安装软件'), isTrue);
    });

    test('纯命令返回 false', () {
      expect(isDescriptiveText('ls -la'), isFalse);
    });

    test('英文描述返回 false（无中文且无描述性开头）', () {
      expect(isDescriptiveText('this is a test'), isFalse);
    });
  });

  group('looksLikeCommand', () {
    test('cat 命令返回 true', () {
      expect(looksLikeCommand('cat file.txt'), isTrue);
    });

    test('systemctl 命令返回 true', () {
      expect(looksLikeCommand('systemctl status nginx'), isTrue);
    });

    test('sudo 命令返回 true', () {
      expect(looksLikeCommand('sudo apt install nginx'), isTrue);
    });

    test('curl 命令返回 true', () {
      expect(looksLikeCommand('curl http://example.com'), isTrue);
    });

    test('Windows 命令 tasklist 返回 true', () {
      expect(looksLikeCommand('tasklist /fi'), isTrue);
    });

    test('过短文本（<3 字符）返回 false', () {
      expect(looksLikeCommand('ab'), isFalse);
    });

    test('中文占比过高返回 false', () {
      expect(looksLikeCommand('请执行这个命令'), isFalse);
    });

    test('不含任何命令关键词的英文返回 false', () {
      expect(looksLikeCommand('hello world'), isFalse);
    });

    test('大小写不敏感', () {
      expect(looksLikeCommand('SUDO apt install'), isTrue);
    });
  });

  group('isTaskComplete', () {
    test('包含"任务完成"返回 true', () {
      expect(isTaskComplete('任务完成'), isTrue);
    });

    test('包含"任务已完成"返回 true', () {
      expect(isTaskComplete('任务已完成'), isTrue);
    });

    test('包含"✅ 任务完成"返回 true', () {
      expect(isTaskComplete('✅ 任务完成'), isTrue);
    });

    test('包含"已完成"返回 true', () {
      expect(isTaskComplete('安装已完成'), isTrue);
    });

    test('包含"操作完成"返回 true', () {
      expect(isTaskComplete('操作完成'), isTrue);
    });

    test('包含"部署完成"返回 true', () {
      expect(isTaskComplete('部署完成'), isTrue);
    });

    test('普通文本返回 false', () {
      expect(isTaskComplete('正在执行命令'), isFalse);
    });

    test('英文文本返回 false', () {
      expect(isTaskComplete('task done'), isFalse);
    });

    test('空字符串返回 false', () {
      expect(isTaskComplete(''), isFalse);
    });

    test('安装已完成（行尾模式）返回 true', () {
      expect(isTaskComplete('安装已完成'), isTrue);
    });

    test('部署完成。（带句末标点）返回 true', () {
      expect(isTaskComplete('部署完成。'), isTrue);
    });

    test('✅ 任务完成。 （emoji + 标点）返回 true', () {
      expect(isTaskComplete('✅ 任务完成。'), isTrue);
    });

    // 误触发修复：AI 思考过程中提到关键词不应判定为完成
    test('我会检查任务完成情况 返回 false（行尾有"情况"）', () {
      expect(isTaskComplete('我会检查任务完成情况'), isFalse);
    });

    test('如果安装完成则继续 返回 false（行尾有"则继续"）', () {
      expect(isTaskComplete('如果安装完成则继续'), isFalse);
    });

    test('已完成了上述步骤 返回 false（关键词后跟动词）', () {
      expect(isTaskComplete('已完成了上述步骤'), isFalse);
    });

    test('AI 长篇思考中偶然出现"任务完成" 返回 false（行过长）', () {
      const longLine = '我现在需要检查系统状态，包括服务运行情况、日志输出、端口监听等，任务完成情况的评估需要等所有检查都做完才能下结论。';
      expect(isTaskComplete(longLine), isFalse);
    });
  });
}
