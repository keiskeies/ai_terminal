import 'package:ai_terminal/services/ssh_service.dart';

/// E2E 用例共用的 SSH 连接。
///
/// 连接失败时必须翻成"凭据或网络问题"。原先直接把 dartssh2 的异常抛出去，
/// 密码打错时输出是一坨 `ssh_transport.dart` 堆栈 + `Some tests failed`，
/// 看起来跟被测代码坏了没有区别 —— 而这些用例默认 skip，能跑到这一步说明
/// 是有人主动按文档来验真机的，误导他一次就浪费一轮。
///
/// 密码不进消息：失败原因里带上它就等于写进测试日志。
Future<void> connectE2ESsh(
  SSHService ssh, {
  required String password,
  required String user,
  required String host,
  required int port,
}) async {
  try {
    await ssh.connect(password: password);
  } catch (e) {
    throw StateError(
      'SSH 连接失败（$user@$host:$port）：这是凭据或网络问题，不是被测代码的缺陷。\n'
      '请确认 E2E_SSH_PASSWORD 正确、目标容器在跑（docker ps）、端口映射没变。\n'
      '原始错误: $e',
    );
  }
}
