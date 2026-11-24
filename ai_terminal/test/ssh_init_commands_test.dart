import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/services/ssh_service.dart';

/// C6：服务器侧 `TMOUT`（等保基线常见 300 s，且常设成 readonly）会让 shell 在
/// 空闲期自己登出——marker 永远不出现，用户看到的是"莫名断线"
/// （docs/ssh-disconnect-resilience-design.md F9）。
/// 初始化串按 shell 类型分支（AGENTS.md R6）：cmd 没有 `unset`，塞进去会多一行报错。
void main() {
  test('POSIX 初始化串先置 0 再 unset', () {
    final s = SSHService.initCommandsFor(remoteIsWindowsCmd: false);
    // 必须带 export：裸赋值 `TMOUT=0 2>/dev/null` 的重定向只作用于命令自身的
    // stderr，"readonly variable" 是 shell 自己报的，这样照样打在用户终端上（bash/dash 实测）。
    expect(s, contains('export TMOUT=0 2>/dev/null;'));
    expect(s, contains('unset TMOUT 2>/dev/null;'),
        reason: 'readonly TMOUT 时赋值会失败，unset 是第二道；两道都要 2>/dev/null');
    expect(s.indexOf('TMOUT=0'), lessThan(s.indexOf('unset TMOUT')));
  });

  test('Windows cmd 分支不含 TMOUT 语法', () {
    final s = SSHService.initCommandsFor(remoteIsWindowsCmd: true);
    expect(s, isNot(contains('TMOUT')));
    expect(s, isNot(contains('unset')));
    // 已知遗留（不在 C6 范围）：alias/LS_COLORS 这几行也是 POSIX 专属，
    // cmd 远端会回显报错。改动前就这样，改它需要在真实 Windows SSH 目标上
    // 验证（见设计文档 §11），本用例刻意不断言。
  });

  test('POSIX 分页器关闭；Windows cmd/PowerShell 不下发 POSIX 初始化', () {
    final posix = SSHService.initCommandsFor(remoteIsWindowsCmd: false);
    // less 停在 (END) 等按键 → 退出码 marker 永不执行 → 命令被判超时
    expect(posix, contains('PAGER=cat'));
    expect(posix, contains('SYSTEMD_PAGER=cat'));

    final windows = SSHService.initCommandsFor(remoteIsWindowsCmd: true);
    expect(windows, isEmpty);
  });
}
