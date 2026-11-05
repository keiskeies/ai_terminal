import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/utils/local_command_detector.dart';
import 'package:ai_terminal/utils/local_shell.dart';

void main() {
  group('buildLocalShellInvocation', () {
    test('PowerShell 置空 LASTEXITCODE 并透传真实退出码', () {
      final inv = buildLocalShellInvocation(
          LocalShellKind.powershell, 'Write-Output hi');
      expect(inv.executable, 'powershell.exe');
      expect(inv.args, containsAllInOrder(['-NoProfile', '-NonInteractive']));
      final script = inv.args.last;
      expect(script, contains(r'$LASTEXITCODE=$null;'));
      expect(script, contains('Write-Output hi'));
      expect(script, contains(r'exit $__ec'));
    });

    test('cmd 用 /d /s /c', () {
      final inv = buildLocalShellInvocation(LocalShellKind.cmd, 'dir');
      expect(inv.executable, 'cmd.exe');
      expect(inv.args, ['/d', '/s', '/c', 'dir']);
    });

    test('bash / sh 用 -lc', () {
      final bash = buildLocalShellInvocation(LocalShellKind.bash, 'uptime');
      expect(bash.executable, 'bash');
      expect(bash.args, ['-lc', 'uptime']);
      final sh = buildLocalShellInvocation(LocalShellKind.sh, 'uptime');
      expect(sh.executable, 'sh');
      expect(sh.args, ['-lc', 'uptime']);
    });
  });

  group('looksLikeLocalWindowsCommand', () {
    test('截图命令（盘符 + 变量赋值 + Select-Object）', () {
      const cmd =
          r'''$dst="D:\docker\images"; mkdir $dst -Force; docker save -o "$dst\all-images.tar" $((docker images -q) | Select-Object -Unique)''';
      expect(looksLikeLocalWindowsCommand(cmd), isTrue);
    });

    test('普通远程 Linux 命令不误判', () {
      expect(looksLikeLocalWindowsCommand('systemctl status nginx'), isFalse);
      expect(looksLikeLocalWindowsCommand('ls -la /var/log'), isFalse);
      expect(looksLikeLocalWindowsCommand(r'grep -r "D:\\" .'), isFalse);
    });

    test('以盘符路径开头的命令', () {
      expect(looksLikeLocalWindowsCommand(r'D:\tools\docker.exe ps'), isTrue);
    });

    test('以 PowerShell 赋值/cmdlet 开头', () {
      expect(looksLikeLocalWindowsCommand(r'$env:PATH'), isTrue);
      expect(looksLikeLocalWindowsCommand('Get-Process docker'), isTrue);
    });
  });

  group('runLocalCommand（Windows 真机）', () {
    test('PowerShell 中文输出与成功退出码', () async {
      final result = await runLocalCommand(
        command: r"Write-Output '本地-中文测试'",
        cwd: Directory.current.path,
        shell: LocalShellKind.powershell,
        timeout: const Duration(seconds: 20),
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('本地-中文测试'));
      expect(result.success, isTrue);
    }, skip: !Platform.isWindows);

    test('原生命令非零退出码不被 cmdlet 吞掉', () async {
      final result = await runLocalCommand(
        command: 'cmd /c exit 7',
        cwd: Directory.current.path,
        shell: LocalShellKind.powershell,
        timeout: const Duration(seconds: 20),
      );
      expect(result.exitCode, 7);
      expect(result.success, isFalse);
    }, skip: !Platform.isWindows);

    test('cmd 分支可执行', () async {
      final result = await runLocalCommand(
        command: 'echo hello',
        cwd: Directory.current.path,
        shell: LocalShellKind.cmd,
        timeout: const Duration(seconds: 20),
      );
      expect(result.exitCode, 0);
      expect(result.stdout.toLowerCase(), contains('hello'));
    }, skip: !Platform.isWindows);
  });
}
