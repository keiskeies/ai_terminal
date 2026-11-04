import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/local_terminal_service.dart';

/// 本地 shell 包装命令的退出码标记（R6 按 shell 分支 / R8 标记必须带数字）。
///
/// 真机缺陷：PowerShell 分支原来是 `echo "MARKER\$LASTEXITCODE"`，而 cmdlet 不设置
/// `$LASTEXITCODE`，渲染出的 `EXITCODE_1:` 冒号后没有数字，完成判定按 `EXITCODE_1:\d+`
/// 匹配（这条严格形状是为了不吃命令回显）→ 每条 cmdlet 都白等满 60 秒并记成失败，
/// 面板显示"0 成功 4 失败"而终端里输出全对。
void main() {
  group('wrapCommandWithExitMarker', () {
    test(r'bash 分支用 $? 且不置空 LASTEXITCODE', () {
      final w = LocalTerminalService.wrapCommandWithExitMarker(
        'uptime',
        'EXITCODE_3:',
        isWindows: false,
        isPowerShell: false,
      );
      expect(w, 'uptime; echo "EXITCODE_3:\$?"');
    });

    test(r'单行命令的 echo 留在同一行，不占 tty 输入队列', () {
      // 分成两行时，`echo ...` 这一行会滞留在 tty 输入队列里。
      // sudo 随后读 /dev/tty 拿密码，就把 marker 行当成第一次密码尝试吃掉：
      // 界面表现为"对不起，请重试"，marker 也永远不出现。
      final w = LocalTerminalService.wrapCommandWithExitMarker(
        'sudo apt update',
        'EXITCODE_1:',
        isWindows: false,
        isPowerShell: false,
      );
      expect(w.split('\n').length, 1, reason: '单行命令不能拆成两行');
      expect(w, contains(r'; echo "EXITCODE_1:$?"'));
    });

    test(r'heredoc 多行命令的 echo 仍必须另起一行', () {
      // 反过来：接在 EOF 后面会让结束标记失效，文件写入永远等不完
      final w = LocalTerminalService.wrapCommandWithExitMarker(
        'cat > /tmp/a <<EOF\nhi\nEOF',
        'EXITCODE_1:',
        isWindows: false,
        isPowerShell: false,
      );
      expect(w, endsWith('\necho "EXITCODE_1:\$?"'));
    });

    test('cmd 分支用 & 与 %errorlevel%', () {
      final w = LocalTerminalService.wrapCommandWithExitMarker(
        'dir',
        'EXITCODE_3:',
        isWindows: true,
        isPowerShell: false,
      );
      expect(w, 'dir & echo EXITCODE_3:%errorlevel%');
    });

    test('PowerShell 分支不再把 \$LASTEXITCODE 直接当值', () {
      final w = LocalTerminalService.wrapCommandWithExitMarker(
        'Get-Date',
        'EXITCODE_3:',
        isWindows: true,
        isPowerShell: true,
      );
      // 旧形状的确切症状：echo "MARKER:$LASTEXITCODE" 对 cmdlet 产出空标记
      expect(w, isNot(contains('EXITCODE_3:\$LASTEXITCODE"')));
      expect(w, contains(r'$?'));
      expect(w, contains('EXITCODE_3:\$__ec"'));
      // 会话级陈旧值防护：必须先置空
      expect(w, startsWith(r'$LASTEXITCODE=$null; '));
    });

    group('真在 PowerShell 里跑一遍（Windows 才跑）', () {
      Future<int?> runAndDetect(String command, String marker) async {
        final wrapped = LocalTerminalService.wrapCommandWithExitMarker(
          command,
          marker,
          isWindows: true,
          isPowerShell: true,
        );
        final r = await Process.run(
          'powershell.exe',
          ['-NoProfile', '-NonInteractive', '-Command', wrapped],
        );
        final out = '${r.stdout}';
        // R8 的完成判定正则必须能吃下这行，否则就是原来的挂死路径
        expect(RegExp('${RegExp.escape(marker)}\\d+').hasMatch(out), isTrue,
            reason: 'marker 未带数字，output=${out.trim()}');
        final digits = RegExp('${RegExp.escape(marker)}(\\d+)')
            .firstMatch(out)
            ?.group(1);
        return digits == null ? null : int.parse(digits);
      }

      test('cmdlet 成功 → 0（旧形状这里产出空标记）', () async {
        expect(await runAndDetect('Get-Date', 'EXITCODE_91:'), 0);
      }, skip: !Platform.isWindows);

      test('原生命令非零退出 → 保留准确码', () async {
        expect(await runAndDetect('cmd /c exit 7', 'EXITCODE_92:'), 7);
      }, skip: !Platform.isWindows);

      test('cmdlet 失败 → 非零', () async {
        expect(await runAndDetect('Get-ChildItem ZzzNotExist', 'EXITCODE_93:'),
            isNonZero);
      }, skip: !Platform.isWindows);

      test('上一条原生命令的陈旧非零值不串到下一条 cmdlet', () async {
        // 会话内先让 native 留一个 7，再跑一条失败的 cmdlet：应报 1 而不是 7
        final wrapped = LocalTerminalService.wrapCommandWithExitMarker(
          'cmd /c exit 7',
          'EXITCODE_94:',
          isWindows: true,
          isPowerShell: true,
        );
        final first = await Process.run(
            'powershell.exe',
            ['-NoProfile', '-NonInteractive', '-Command', wrapped]);
        expect(RegExp('EXITCODE_94:7').hasMatch('${first.stdout}'), isTrue);
        // 第二条复用同一会话变量语义（新的 powershell 进程自然为 null，
        // 这里检验的是同一条命令内 native→cmdlet 的组合形状）
        final combo = LocalTerminalService.wrapCommandWithExitMarker(
          'cmd /c exit 0; Get-ChildItem ZzzNotExist',
          'EXITCODE_95:',
          isWindows: true,
          isPowerShell: true,
        );
        final second = await Process.run(
            'powershell.exe',
            ['-NoProfile', '-NonInteractive', '-Command', combo]);
        expect(
            RegExp('EXITCODE_95:(\\d+)').firstMatch('${second.stdout}')?.group(1),
            '1',
            reason: 'cmdlet 失败不能被前一条原生命令的 0 冒充成功');
      }, skip: !Platform.isWindows);
    });
  });
}
