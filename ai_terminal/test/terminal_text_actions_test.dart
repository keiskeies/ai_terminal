import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/terminal_text_actions.dart';

void main() {
  group('URL / 路径识别', () {
    test('识别行内 URL 并去掉尾部标点', () {
      expect(
        detectUrl('详见 https://example.com/docs/install.html。'),
        'https://example.com/docs/install.html',
      );
      expect(
        detectUrl('(see http://10.0.0.5:8080/status)'),
        'http://10.0.0.5:8080/status',
      );
      expect(detectUrl('没有链接的一行'), isNull);
    });

    test('Windows 盘符路径优先，POSIX 路径也能识别', () {
      expect(detectPath(r'copy C:\Windows\Temp\a.log to backup'),
          r'C:\Windows\Temp\a.log');
      expect(detectPath('打开 /var/log/nginx/error.log 看看'),
          '/var/log/nginx/error.log');
      expect(detectPath('cat ~/deploy/run.sh'), '~/deploy/run.sh');
      expect(detectPath('just some words'), isNull);
    });
  });

  group('报错 / 命令判定', () {
    test('中英文报错都能识别', () {
      expect(looksLikeError('Error: connection refused'), isTrue);
      expect(looksLikeError('java.lang.NullPointerException'), isTrue);
      expect(looksLikeError('操作失败：权限不足'), isTrue);
      expect(looksLikeError('deploy finished successfully'), isFalse);
    });

    test('多行粘贴需要确认', () {
      expect(isMultiLine('ls\ncd /tmp'), isTrue);
      expect(isMultiLine('ls\r\ncd /tmp'), isTrue);
      expect(isMultiLine('ls -la'), isFalse);
    });

    test('像命令的选中内容才会给"执行"入口', () {
      expect(looksLikeCommand('systemctl restart nginx'), isTrue);
      expect(looksLikeCommand(r'C:\Tools\check.exe --verbose'), isTrue);
      expect(looksLikeCommand(r'$ ls -la'), isTrue);
      expect(looksLikeCommand('PS C:\\Users\\Administrator> dir'), isTrue);
      expect(looksLikeCommand('这台机器的磁盘占用是多少'), isFalse);
      expect(looksLikeCommand('Error: file not found'), isFalse);
      expect(looksLikeCommand('ls\nrm -rf /'), isFalse);
    });

    test('去掉提示符前缀', () {
      expect(stripPromptPrefix(r'PS C:\Users\me> ls -la'), 'ls -la');
      expect(stripPromptPrefix(r'me@web-01:~$ docker ps'), 'docker ps');
      expect(stripPromptPrefix('ls -la'), 'ls -la');
    });
  });

  test('取路径所在目录（SFTP 定位用）', () {
    expect(directoryOfPath('/var/log/nginx/error.log'), '/var/log/nginx');
    expect(directoryOfPath('~/deploy/run.sh'), '~/deploy');
    expect(directoryOfPath('/tmp'), '/');
    expect(directoryOfPath('relative.txt'), '.');
  });

  test('发给 Agent 的提示词带代码块包裹', () {
    expect(agentExplainPrompt('  df -h  '), contains('```\ndf -h\n```'));
    expect(agentErrorPrompt('Error: boom'), contains('```\nError: boom\n```'));
  });
}
