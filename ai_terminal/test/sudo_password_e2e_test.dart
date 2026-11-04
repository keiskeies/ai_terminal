import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/ssh_service.dart';

/// 真机 sudo 密码应答 E2E
///
/// 复现用户实机（Debian，中文 locale）的故障：`sudo apt update` 卡在
/// `[sudo] cjm 的密码：`，密码永远注入不进去，界面上反复出现"对不起，请重试"。
/// 这条链路单元测试覆盖不到 —— 真正的失败发生在 PTY 输出缓冲、marker 等待
/// 与交互式提示检测三者的竞态上，只有真 SSH + 真 PTY 才能验。
///
/// 需要的目标机：Debian/Ubuntu、登录用户属于 sudo 组、且 sudo **需要**密码，
/// 并装有 zh_CN.UTF-8 locale（中文提示那条用例依赖它）。一次性容器：
///   docker build -t sudo-e2e-debian - <<'EOF'
///   FROM debian:latest
///   RUN apt-get update && apt-get install -y --no-install-recommends \
///       openssh-server sudo locales && rm -rf /var/lib/apt/lists/*
///   RUN sed -i 's/^# *zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen && locale-gen \
///       && mkdir -p /run/sshd
///   RUN useradd -m -s /bin/bash cjm && echo 'cjm:<你的测试密码>' | chpasswd \
///       && usermod -aG sudo cjm && echo 'Defaults lecture=never' >> /etc/sudoers
///   CMD ["/bin/sh", "-c", "ssh-keygen -A && exec /usr/sbin/sshd -D -e"]
///   EOF
///   docker run -d --name sudo-e2e-debian -p 10222:22 sudo-e2e-debian
///
/// 环境变量（密码只从环境读，不要写进文件）：
///   E2E_SUDO_HOST / E2E_SUDO_PORT / E2E_SUDO_USER
///   E2E_SUDO_LOGIN_PASSWORD / E2E_SUDO_PASSWORD
final _env = Platform.environment;
final _host = _env['E2E_SUDO_HOST'];
final _user = _env['E2E_SUDO_USER'];
final _loginPassword = _env['E2E_SUDO_LOGIN_PASSWORD'];
final _sudoPassword = _env['E2E_SUDO_PASSWORD'];
final _port = int.tryParse(_env['E2E_SUDO_PORT'] ?? '') ?? 22;
final _enabled = [_host, _user, _loginPassword, _sudoPassword]
    .every((v) => v != null && v.isNotEmpty);

const _skipReason = 'Set E2E_SUDO_HOST / E2E_SUDO_USER / '
    'E2E_SUDO_LOGIN_PASSWORD / E2E_SUDO_PASSWORD to run';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (!L10n.isReady) {
      L10n.setup(AppLocalizationsZh());
    }
  });

  group('sudo 密码应答 E2E', skip: _enabled ? false : _skipReason, () {
    late SSHService ssh;

    setUp(() async {
      final config = HostConfig.create(
        id: 'e2e-sudo',
        name: 'E2E Sudo',
        host: _host!,
        port: _port,
        username: _user!,
        authType: 'password',
      );
      ssh = SSHService(config);
      await ssh.connect(password: _loginPassword!);
      expect(ssh.isConnected, isTrue, reason: 'SSH 连接失败，后面的用例没有意义');
    });

    tearDown(() async {
      await ssh.disconnect();
    });

    test('不传密码时明确报 interactivePrompt，而不是干等到超时', () async {
      final result = await ssh.executeAndWait(
        'sudo -k id',
        timeout: const Duration(seconds: 20),
      );
      expect(result.failureKind, CommandFailureKind.interactivePrompt,
          reason: '未配置密码时必须快速失败并把原因交给 AI，'
              '否则用户只能看着命令卡死');
      expect(result.stdout, contains('[sudo]'),
          reason: '提示原文要留在输出里，AI 才知道是 sudo 而不是别的程序');
    });

    test('传密码后 sudo 命令成功执行', () async {
      final result = await ssh.executeAndWait(
        'sudo -k id',
        timeout: const Duration(seconds: 30),
        sudoPassword: _sudoPassword,
      );
      expect(result.failureKind, CommandFailureKind.none,
          reason: '应答失败会被检测器抢先用 Ctrl+C 打断（本次修的就是这个竞态）');
      expect(result.exitCode, 0);
      expect(result.stdout, contains('uid=0'));
    });

    test('中文 locale 的 sudo 提示同样被应答', () async {
      // 先确认容器真的吐出了本地化提示 —— 否则这个用例并没有测到修复点
      final probe = await ssh.executeAndWait(
        'LANG=zh_CN.UTF-8 sudo -k id',
        timeout: const Duration(seconds: 20),
      );
      expect(probe.failureKind, CommandFailureKind.interactivePrompt);
      expect(probe.stdout, contains('的密码'),
          reason: '没复现出中文提示说明容器 locale 不对，这个用例等于没跑');

      final answered = await ssh.executeAndWait(
        'LANG=zh_CN.UTF-8 sudo -k id',
        timeout: const Duration(seconds: 30),
        sudoPassword: _sudoPassword,
      );
      expect(answered.failureKind, CommandFailureKind.none);
      expect(answered.exitCode, 0,
          reason: '用户实机正是卡死在这一步：英文整句匹配不上中文提示');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('探测失败后立即重试（AI 的真实流程：失败 → 收密码 → 重试）', () async {
      // 这条测的是 Ctrl+C 之后的竞态：被 interrupt 的 sudo 还活着，会把 tty 输入
      // 队列里的字节当密码尝试吃掉。不 settle 就重试，整条重试命令会被吞掉，
      // marker 永不出现 → 干等满超时。真机复现过，单元测试测不出来。
      final probe = await ssh.executeAndWait(
        'sudo -k id',
        timeout: const Duration(seconds: 20),
      );
      expect(probe.failureKind, CommandFailureKind.interactivePrompt);

      final retry = await ssh.executeAndWait(
        'sudo -k id',
        timeout: const Duration(seconds: 30),
        sudoPassword: _sudoPassword,
      );
      expect(retry.failureKind, CommandFailureKind.none,
          reason: '重试命令被上一个 sudo 的残骸吃掉时，failureKind 是 timeout');
      expect(retry.exitCode, 0);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('密码只写进 stdin，不出现在命令串与输出里', () async {
      final result = await ssh.executeAndWait(
        'sudo -k id',
        timeout: const Duration(seconds: 30),
        sudoPassword: _sudoPassword,
      );
      expect(result.stdout, isNot(contains(_sudoPassword)),
          reason: '密码进了 stdout 就会进对话历史并被模型读到（R7）');
    });

    test('密码错误时命令失败而不是无限等待', () async {
      final result = await ssh.executeAndWait(
        'sudo -k id',
        timeout: const Duration(seconds: 40),
        sudoPassword: 'definitely-not-the-password',
      );
      expect(result.exitCode, isNot(0));
      expect(result.timedOut, isFalse,
          reason: '答错后 sudo 会重试并最终退出，marker 仍要出现');
    });

    test('用户实机命令 sudo apt update 走长超时并成功', () async {
      final result = await ssh.executeAndWait(
        'sudo -k apt-get update',
        timeout: const Duration(minutes: 3),
        sudoPassword: _sudoPassword,
      );
      expect(result.failureKind, CommandFailureKind.none);
      expect(result.exitCode, 0);
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}
