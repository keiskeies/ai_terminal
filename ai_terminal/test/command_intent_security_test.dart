import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/permission_policy.dart';
import 'package:ai_terminal/core/safety_guard.dart';
import 'package:ai_terminal/core/security/command_intent.dart';
import 'package:ai_terminal/models/agent_permission_mode.dart';

void main() {
  group('保守命令意图', () {
    test('未知可执行程序不得默认 safe', () {
      expect(SafetyGuard.check('totally-unknown-tool --do-work'),
          SafetyLevel.warn);
      expect(
          SafetyGuard.intent('totally-unknown-tool --do-work').conservativeSafe,
          isFalse);
    });

    test('解析结果保留可执行程序与参数', () {
      final intent = SafetyGuard.intent('grep -n error app.log');
      expect(intent.executable, 'grep');
      expect(intent.arguments, ['-n', 'error', 'app.log']);
      expect(intent.shell, 'posix');
      expect(intent.conservativeSafe, isTrue);
      expect(intent.confidence, greaterThan(0.9));
    });

    test('只读白名单与管道保持 safe', () {
      expect(SafetyGuard.check('ps aux | grep nginx | tail -10'),
          SafetyLevel.safe);
      expect(SafetyGuard.check('df -h && free -m'), SafetyLevel.safe);
      expect(SafetyGuard.check('echo "rm x"'), SafetyLevel.safe);
      expect(SafetyGuard.check(r"echo '$(rm x)'"), SafetyLevel.safe);
    });

    test('转义引号后的注释字符仍属于参数', () {
      const command = "grep -E -- 'x'\\''; touch /tmp/pwn; #' /tmp/a";
      expect(SafetyGuard.check(command), SafetyLevel.safe);
      expect(SafetyGuard.intent(command).unresolved, isEmpty);
      expect(SafetyGuard.check('md5sum -- /tmp/a'), SafetyLevel.safe);
    });

    test('引号内的只读 cmdlet 文本不误判', () {
      expect(SafetyGuard.check(r'Get-ChildItem C:\Windows'), SafetyLevel.safe);
      expect(SafetyGuard.check(r'Test-Path D:\tmp\a.txt'), SafetyLevel.safe);
      expect(SafetyGuard.check(r'Get-Content D:\tmp\a.txt'), SafetyLevel.safe);
      expect(SafetyGuard.check('echo "Set-Content"'), SafetyLevel.safe);
      expect(
          SafetyGuard.check(
              "powershell -NoProfile -Command \"[Environment]::GetFolderPath('Desktop')\""),
          SafetyLevel.safe);
      expect(
          SafetyGuard.check(
              r"powershell -NoProfile -Command Get-Item 'C:\a.txt' | Select-Object Length"),
          SafetyLevel.safe);
    });

    test('命令替换与动态变量不能证明只读', () {
      const commands = [
        r'echo "$(rm -rf /tmp/x)"',
        'echo `id`',
        r'cat "$HOME/.ssh/id_rsa"',
        r'echo %COMSPEC%',
        r'echo !PATH!',
        r'powershell -Command "& $env:COMSPEC calc"',
        'cat <(printf data)',
      ];
      for (final command in commands) {
        expect(SafetyGuard.check(command), SafetyLevel.warn, reason: command);
        expect(SafetyGuard.intent(command).unresolved, isNotEmpty,
            reason: command);
      }
    });

    test('内联解释器代码与编码命令保持未知', () {
      const commands = [
        "bash -c 'cat /etc/passwd'",
        "sh -lc 'ls'",
        "python3 -c 'print(1)'",
        "node -e 'console.log(1)'",
        "perl -e 'print 1'",
        "ruby -e 'puts 1'",
        r'powershell -EncodedCommand SQBuAHYAbwBrAGUALQBFAHkAbABsAGEAdABlAA==',
      ];
      for (final command in commands) {
        expect(SafetyGuard.check(command), SafetyLevel.warn, reason: command);
        expect(SafetyGuard.intent(command).unresolved, isNotEmpty,
            reason: command);
      }
    });

    test('输出重定向与 heredoc 不属于 safe', () {
      expect(SafetyGuard.check('echo data > ~/.bashrc'), SafetyLevel.warn);
      expect(SafetyGuard.check('cat > /tmp/a.txt <<EOF\nhello\nEOF'),
          SafetyLevel.warn);
      expect(
          SafetyGuard.intent('cat <<EOF\nhello\nEOF').unresolved,
          contains(predicate<Object>(
              (e) => e is UnresolvedConstruct && e.kind == 'heredoc')));
    });

    test('权限与环境包装器效果不能被剥离后遗忘', () {
      expect(SafetyGuard.check('sudo cat /etc/passwd'), SafetyLevel.warn);
      expect(SafetyGuard.check('env PATH=/evil cat /etc/passwd'),
          SafetyLevel.warn);
      expect(SafetyGuard.check('timeout 5 cat /etc/passwd'), SafetyLevel.warn);
      expect(SafetyGuard.intent('sudo cat /etc/passwd').effects,
          contains(CommandEffect.privilegeEscalation));
    });

    test('原有写命令与高危命令等级不降低', () {
      expect(SafetyGuard.check(r'Set-Content -Path a.txt -Value 1'),
          SafetyLevel.warn);
      expect(SafetyGuard.check(r'cmd /c "del C:\tmp\a"'), SafetyLevel.warn);
      expect(
          SafetyGuard.check("sed -E -i 's/a/b/' app.conf"), SafetyLevel.warn);
      expect(SafetyGuard.check('rm -rf /'), SafetyLevel.blocked);
      expect(SafetyGuard.check(r'r\m -rf /'), SafetyLevel.blocked);
    });

    test('ip / ss 的修改子命令不属于只读', () {
      expect(SafetyGuard.check('ip addr add 10.0.0.1/24 dev eth0'),
          SafetyLevel.warn);
      expect(SafetyGuard.check('ip link set eth0 down'), SafetyLevel.warn);
      expect(SafetyGuard.check('ip netns exec ns1 sh'), SafetyLevel.warn);
      expect(SafetyGuard.check('ip neigh flush all'), SafetyLevel.warn);
      expect(SafetyGuard.check('ss -K dst 10.0.0.1'), SafetyLevel.warn);
      expect(SafetyGuard.check('ss --kill'), SafetyLevel.warn);
      expect(SafetyGuard.check('ip addr show'), SafetyLevel.safe);
      expect(SafetyGuard.check('ss -tlnp'), SafetyLevel.safe);
      expect(SafetyGuard.check('netstat -rn'), SafetyLevel.safe);
    });

    test('export 修改环境变量不能落入 info 快通道', () {
      expect(SafetyGuard.check('export PATH=/tmp/evil'), SafetyLevel.warn);
      expect(SafetyGuard.check('export PATH=/tmp/evil; ls'), SafetyLevel.warn);
    });

    test('PowerShell 反斜杠路径保留为字面量', () {
      final direct = SafetyGuard.intent(r'Get-Content C:\Windows\win.ini');
      expect(direct.executable, 'get-content');
      expect(direct.arguments, [r'C:\Windows\win.ini']);
      expect(direct.conservativeSafe, isTrue);

      final wrapped = SafetyGuard.intent(
          r'powershell -NoProfile -Command "Get-Content C:\Windows\win.ini"');
      expect(wrapped.executable, 'get-content');
      expect(wrapped.arguments, [r'C:\Windows\win.ini']);
      expect(wrapped.conservativeSafe, isTrue);
    });

    test('PowerShell 反引号按转义处理，未闭合时 fail closed', () {
      final escaped = SafetyGuard.intent(r'Get-Content C:\tmp\`$env:SECRET');
      expect(escaped.arguments, [r'C:\tmp\$env:SECRET']);
      expect(escaped.conservativeSafe, isTrue);

      expect(SafetyGuard.check(r'Get-Content C:\tmp\`$env:SECRET'),
          SafetyLevel.safe);
      expect(SafetyGuard.check(r'Get-Content C:\tmp\`'), SafetyLevel.warn);
      expect(
          SafetyGuard.intent(r'Get-Content C:\tmp\`').unresolved,
          contains(predicate<Object>(
              (e) => e is UnresolvedConstruct && e.kind == 'dangling_escape')));
    });

    test('未闭合引号和悬空转义 fail closed', () {
      expect(SafetyGuard.check("echo 'unterminated"), SafetyLevel.warn);
      expect(SafetyGuard.check('echo trailing\\'), SafetyLevel.warn);
    });
  });

  group('未知命令权限决策', () {
    test('只读拒绝，询问要求确认，全自动显式放行', () {
      const command = 'unknown-tool --change';
      expect(
          decideCommand(
              SafetyGuard.check(command), AgentPermissionMode.readOnly),
          CommandGateDecision.reject);
      expect(decideCommand(SafetyGuard.check(command), AgentPermissionMode.ask),
          CommandGateDecision.confirm);
      expect(
          decideCommand(
              SafetyGuard.check(command), AgentPermissionMode.fullAuto),
          CommandGateDecision.execute);
    });
  });
}
