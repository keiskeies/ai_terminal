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
  });
}
