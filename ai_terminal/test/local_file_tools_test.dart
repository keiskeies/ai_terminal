import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ai_terminal/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:ai_terminal/pages/agent_settings_page.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/daos.dart';
import 'package:ai_terminal/services/local_file_policy.dart';
import 'package:ai_terminal/services/local_access.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/local_file_tools.dart';
import 'package:ai_terminal/utils/local_file_ops.dart';
import 'package:ai_terminal/services/ssh_service.dart';
import 'package:ai_terminal/services/file_sync_service.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

/// 本地文件工具不经过 shell，所以不需要真 executor；
/// 这些测试只证明"策略判定 + 文件语义"，不测 SSH 路径。
class _NullExecutor implements CommandExecutor {
  @override
  bool get isConnected => true;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  void execute(String command) {}
  @override
  Future<CommandResult> executeAndWait(String command,
          {Duration timeout = const Duration(seconds: 1),
          Completer<void>? cancelToken,
          String? sudoPassword,
          Future<String?> Function(String prompt)?
              onInteractivePrompt}) async =>
      CommandResult(
          stdout: '', stderr: '', exitCode: 0, duration: Duration.zero);
  @override
  Future<String> runOnce(String command,
          {Duration timeout = const Duration(seconds: 1)}) async =>
      '';
  @override
  Future<CommandResult> writeFileViaPty(
          {required String path,
          required Uint8List content,
          bool useSudo = false,
          Duration timeout = const Duration(seconds: 1),
          Completer<void>? cancelToken}) async =>
      CommandResult(
          stdout: '', stderr: '', exitCode: 0, duration: Duration.zero);
  @override
  void writeToTerminal(String data) {}
}

Future<void> _configurePolicy({
  required bool enabled,
  required List<String> dirs,
}) async {
  await SettingsDao.set('localFilePolicy', {
    'enabled': enabled,
    'allowedDirs': dirs,
    'maxReadBytes': 2 * 1024 * 1024,
  });
}

Future<ToolResult> _run(AgentTool tool, Map<String, dynamic> args) =>
    tool.execute(executor: _NullExecutor(), args: ToolArgs(args));

void main() {
  late Directory sandbox;
  late Directory outside;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('ai_local_tools_');
    outside = await Directory.systemTemp.createTemp('ai_outside_');
    // 系统临时目录在 macOS 上会解析成 /private/var/...，统一用真实路径做白名单
    sandbox = Directory(await sandbox.resolveSymbolicLinks());
    outside = Directory(await outside.resolveSymbolicLinks());
    await _configurePolicy(enabled: true, dirs: [sandbox.path]);
  });

  tearDown(() async {
    await _configurePolicy(enabled: false, dirs: []);
    for (final d in [sandbox, outside]) {
      try {
        await d.delete(recursive: true);
      } catch (_) {}
    }
  });

  String sandboxFile(String name, String content) {
    final f = File(p.join(sandbox.path, name));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return p.normalize(f.path);
  }

  group('LocalFilePolicy 判定', () {
    test('总开关关闭时拒绝访问，敏感路径与回收区仍优先拦截', () async {
      await _configurePolicy(enabled: false, dirs: [sandbox.path]);
      final path = p.join(outside.path, 'outside.txt');
      File(path).writeAsStringSync('hello');
      final r = await _run(LocalFileReadTool(), {'path': path});
      expect(r.success, isFalse);
      expect(r.error, contains('总开关已关闭'));
      final sensitive = File(p.join(sandbox.path, '.env'))
        ..writeAsStringSync('SECRET=1');
      final blocked = await _run(LocalFileReadTool(), {'path': sensitive.path});
      expect(blocked.success, isFalse);
      expect(blocked.error, contains('敏感'));
    });

    test('白名单外的路径被拒绝', () async {
      final path = sandboxFile('a.txt', 'hello');
      final outsideFile = File('${outside.path}/secret.txt')
        ..writeAsStringSync('secret');
      final r = await _run(LocalFileReadTool(), {'path': outsideFile.path});
      expect(r.success, isFalse);
      expect(r.error, contains('不在授权目录内'));
      // 白名单内的文件仍可读
      expect((await _run(LocalFileReadTool(), {'path': path})).success, isTrue);
    });

    test('用 .. 跳出授权目录被拒绝', () async {
      // 只授权 sandbox/allowed，然后尝试用 .. 读同级的其它文件
      final allowed = Directory('${sandbox.path}/allowed')..createSync();
      File('${allowed.path}/inside.txt').writeAsStringSync('ok');
      File('${sandbox.path}/other.txt').writeAsStringSync('not ok');
      await _configurePolicy(enabled: true, dirs: [allowed.path]);

      final inside = await _run(
          LocalFileReadTool(), {'path': '${allowed.path}/inside.txt'});
      expect(inside.success, isTrue);

      final escape = await _run(LocalFileReadTool(), {
        'path': '${allowed.path}/../other.txt',
      });
      expect(escape.success, isFalse, reason: '归一化后落在授权目录外，必须拒绝');
      expect(File('${sandbox.path}/other.txt').readAsStringSync(), 'not ok',
          reason: '拒绝发生在任何 I/O 之前');
    });

    test('读取按单行与整段字符上限截断', () async {
      final path = sandboxFile(
          'long.txt',
          '${'A' * 3000}\n'
              '${List.generate(30, (_) => 'B' * 1000).join('\n')}');
      final r =
          await _run(LocalFileReadTool(), {'path': path, 'max_lines': 5000});
      expect(r.success, isTrue);
      final out = r.output;
      expect(out, contains('行过长'));
      expect(out, contains('用 start_line:'));
      expect(out.length, lessThan(25000));
    });

    test('敏感文件即使在白名单内也拒绝', () async {
      final sshDir = Directory('${sandbox.path}/.ssh')
        ..createSync(recursive: true);
      final key = File('${sshDir.path}/id_rsa')
        ..writeAsStringSync('PRIVATE KEY');
      final r = await _run(LocalFileReadTool(), {'path': key.path});
      expect(r.success, isFalse);
      expect(r.error, contains('敏感'));
    });

    test('.env 文件被黑名单拦住', () async {
      final env = File('${sandbox.path}/.env')..writeAsStringSync('A=1');
      final r = await _run(LocalFileReadTool(), {'path': env.path});
      expect(r.success, isFalse);
    });

    test('符号链接指向白名单外时拒绝', () async {
      // Windows 上创建符号链接需要特权或开发者模式，失败就跳过这条
      if (Platform.isWindows) return;
      final target = File('${outside.path}/real.txt')
        ..writeAsStringSync('outside content');
      final link = Link('${sandbox.path}/evil');
      try {
        link.createSync(target.path);
      } catch (_) {
        return; // 文件系统不支持链接，跳过
      }
      expect(link.existsSync(), isTrue);
      final r = await _run(LocalFileReadTool(), {'path': link.path});
      expect(r.success, isFalse, reason: '链接解析后落在沙箱外');
      expect(target.existsSync(), isTrue, reason: '拒绝不得影响目标文件');
    });

    test('断链解析失败必须拒绝，不能按字面路径放行', () {
      final link = Link(p.join(sandbox.path, 'broken-link'));
      try {
        link.createSync(p.join(outside.path, 'missing-target.txt'));
      } catch (_) {
        if (Platform.isWindows) return; // 未开发者模式时跳过
      }
      final decision = LocalFilePolicy.load().decide(link.path);
      expect(decision.isAllowed, isFalse);
      expect(decision.verdict, LocalPathVerdict.escape);
      expect(decision.reason, contains('符号链接解析失败'));
    });

    test('校验后 link-swap 再验证必须失败并保护目标文件', () {
      final allowedTarget = File(p.join(sandbox.path, 'real.txt'))
        ..writeAsStringSync('allowed');
      final outsideTarget = File(p.join(outside.path, 'secret.txt'))
        ..writeAsStringSync('secret');
      final link = Link(p.join(sandbox.path, 'swap-link'));
      try {
        link.createSync(allowedTarget.path);
      } catch (_) {
        if (Platform.isWindows) return; // 未开发者模式时跳过
      }
      final policy = LocalFilePolicy.load();
      final first = policy.decide(link.path);
      expect(first.isAllowed, isTrue);
      link.deleteSync();
      link.createSync(outsideTarget.path);
      final swapped = policy.verify(link.path, first.resolved);
      expect(swapped.isAllowed, isFalse);
      expect(swapped.verdict, LocalPathVerdict.escape);
      expect(outsideTarget.readAsStringSync(), 'secret');
    });

    test('规范化结果不保留重复根分隔符', () {
      final raw =
          '${sandbox.path}${Platform.pathSeparator}${Platform.pathSeparator}new.txt';
      final decision = LocalFilePolicy.load().decide(raw);
      expect(decision.isAllowed, isTrue);
      expect(decision.resolved.replaceAll(r'\', '/'), isNot(contains('//')));
    });

    test('POSIX 授权根目录 / 允许其下所有非敏感路径', () {
      if (Platform.isWindows) return;
      const policy = LocalFilePolicy(enabled: true, allowedDirs: ['/']);
      final path = p.join(Directory.systemTemp.path, 'root-policy-file.txt');
      expect(policy.decide(path).isAllowed, isTrue);
      expect(policy.decide('/etc/hosts').verdict, LocalPathVerdict.sensitive);
    });

    test('decide 直接判定：新建文件（末段不存在）也允许', () {
      final policy = LocalFilePolicy.load();
      final d = policy.decide('${sandbox.path}/new/deep/file.txt');
      expect(d.isAllowed, isTrue, reason: '允许在授权目录里创建新路径');
      expect(d.resolved, contains('file.txt'));
    });
  });

  group('local_file_read / dir_list / search', () {
    test('read 带行号并支持分段', () async {
      final path = sandboxFile('x.txt', 'l1\nl2\nl3\nl4');
      final r = await _run(LocalFileReadTool(), {'path': path});
      expect(r.success, isTrue);
      expect(r.output, contains('1\tl1'));
      expect(r.output, contains('共 4 行'));

      final part = await _run(
          LocalFileReadTool(), {'path': path, 'start_line': 3, 'max_lines': 1});
      expect(part.output, contains('3\tl3'));
      expect(part.output, isNot(contains('4\tl4')));
    });

    test('read 目录/不存在/二进制都给出明确错误', () async {
      expect((await _run(LocalFileReadTool(), {'path': sandbox.path})).success,
          isFalse);
      final missing =
          await _run(LocalFileReadTool(), {'path': '${sandbox.path}/nope.txt'});
      expect(missing.error, contains('不存在'));
      final bin = File('${sandbox.path}/bin.dat')
        ..writeAsBytesSync([0, 1, 2, 255, 254]);
      final br = await _run(LocalFileReadTool(), {'path': bin.path});
      expect(br.success, isFalse);
    });

    test('dir_list 跳过 .git 并标注目录', () async {
      Directory('${sandbox.path}/src').createSync();
      Directory('${sandbox.path}/.git').createSync();
      File('${sandbox.path}/src/main.dart').writeAsStringSync('void main(){}');
      final r = await _run(LocalDirListTool(), {'path': sandbox.path});
      expect(r.success, isTrue);
      expect(r.output, contains('src/'));
      expect(r.output, contains('.git/  (已跳过)'));
      expect(r.output, isNot(contains('main.dart')), reason: 'depth=1 不进子目录');

      final deep =
          await _run(LocalDirListTool(), {'path': sandbox.path, 'depth': 2});
      expect(deep.output, contains('main.dart'));
    });

    test('search 返回 path:line 且受 glob 限制', () async {
      sandboxFile('a.txt', 'needle here\nnothing');
      sandboxFile('b.log', 'needle in log');
      final all = await _run(
          LocalFileSearchTool(), {'path': sandbox.path, 'query': 'needle'});
      expect(all.success, isTrue);
      expect(all.output, contains('2 处命中'));

      final only = await _run(LocalFileSearchTool(), {
        'path': sandbox.path,
        'query': 'needle',
        'glob': '*.txt',
      });
      expect(only.output, contains('a.txt:1:'));
      expect(only.output, isNot(contains('b.log')));

      final none = await _run(
          LocalFileSearchTool(), {'path': sandbox.path, 'query': 'zzz'});
      expect(none.output, contains('未命中'));
    });

    test('search 报告超大文件跳过且不计入已扫描', () async {
      sandboxFile('ok.txt', 'needle');
      File(p.join(sandbox.path, 'huge.txt'))
        ..writeAsBytesSync(List<int>.filled(3 * 1024 * 1024, 0));
      final r = await _run(
          LocalFileSearchTool(), {'path': sandbox.path, 'query': 'needle'});
      expect(r.success, isTrue);
      final out = r.output;
      expect(out, contains('1 处命中（扫描 1 个文件）'));
      expect(out, contains('超过 2MB'));
      expect(out, contains('huge.txt'));
    });

    test('递归 search 逐个授权后代并报告敏感文件跳过', () async {
      sandboxFile('safe.txt', 'SAFE_SENTINEL');
      sandboxFile('nested/.env', 'SECRET=ENV_SENTINEL');
      sandboxFile('nested/.ssh/id_rsa', 'PRIVATE_KEY_SENTINEL');
      sandboxFile('nested/private.key', 'PRIVATE_FILE_SENTINEL');
      sandboxFile('nested/.ai_terminal_trash/copy.txt', 'TRASH_SENTINEL');

      final result = await _run(LocalFileSearchTool(), {
        'path': sandbox.path,
        'query': 'SENTINEL',
      });

      expect(result.success, isTrue, reason: result.error ?? result.output);
      expect(result.output, contains('safe.txt:1: SAFE_SENTINEL'));
      expect(result.output, contains('1 处命中（扫描 1 个文件）'));
      expect(result.output, contains('已跳过 4 个未获授权/敏感文件'));
      expect(result.output, contains('.env'));
      expect(result.output, contains('id_rsa'));
      expect(result.output, contains('private.key'));
      expect(result.output, contains('.ai_terminal_trash'));
      expect(result.output, isNot(contains('ENV_SENTINEL')));
      expect(result.output, isNot(contains('PRIVATE_KEY_SENTINEL')));
      expect(result.output, isNot(contains('PRIVATE_FILE_SENTINEL')));
      expect(result.output, isNot(contains('TRASH_SENTINEL')));
    });
  });

  group('local_file_write / patch', () {
    test('新建文件成功；覆盖前自动备份', () async {
      final path = '${sandbox.path}/cfg.conf';
      final first =
          await _run(LocalFileWriteTool(), {'path': path, 'content': 'a=1'});
      expect(first.success, isTrue);
      expect(File(path).readAsStringSync(), 'a=1');

      final second =
          await _run(LocalFileWriteTool(), {'path': path, 'content': 'a=2'});
      expect(second.success, isTrue);
      expect(second.output, contains('原文件已备份'));
      expect(File(path).readAsStringSync(), 'a=2');
      final backups = sandbox
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('cfg.conf.bak.'))
          .toList();
      expect(backups, hasLength(1));
      expect(backups.single.readAsStringSync(), 'a=1');
    });

    test('content 里的 \\n 转义会还原成真实换行', () async {
      final path = '${sandbox.path}/multi.txt';
      final r = await _run(
          LocalFileWriteTool(), {'path': path, 'content': 'l1\\nl2\\tl3'});
      expect(r.success, isTrue);
      expect(File(path).readAsStringSync(), 'l1\nl2\tl3');
    });

    test('write 空 content 被拒绝，不能把已有文件截断还报成功', () async {
      final path = sandboxFile('keep.txt', 'keep me');
      final r = await _run(LocalFileWriteTool(), {'path': path, 'content': ''});
      expect(r.success, isFalse);
      expect(r.error, contains('不能为空'));
      expect(File(path).readAsStringSync(), 'keep me');
    });

    test('append 要求文件已存在；超 8KB 拒绝并教分块', () async {
      final missing = await _run(LocalFileWriteTool(), {
        'path': '${sandbox.path}/none.txt',
        'mode': 'append',
        'content': 'x'
      });
      expect(missing.success, isFalse);
      expect(missing.error, contains('append'));

      final big = await _run(LocalFileWriteTool(),
          {'path': '${sandbox.path}/big.txt', 'content': 'x' * 9000});
      expect(big.success, isFalse);
      expect(big.error, contains('分块'));
    });

    test('写前策略收缩后拒绝覆盖并保留原内容', () async {
      final path = sandboxFile('policy-change.txt', 'original');
      const allowed = LocalFilePolicy(enabled: true, allowedDirs: []);
      var checks = 0;
      final result = await _run(
        LocalFileWriteTool(policyLoader: () {
          // 前几次检查覆盖初始解析/备份；随后模拟用户在写入前撤销授权。
          return checks++ < 5
              ? LocalFilePolicy(enabled: true, allowedDirs: [sandbox.path])
              : allowed;
        }),
        {'path': path, 'content': 'replacement'},
      );
      expect(checks, greaterThanOrEqualTo(5));
      expect(result.success, isFalse);
      expect(result.error, contains('授权'));
      expect(File(path).readAsStringSync(), 'original');
    });

    test('patch 非 UTF-8 字节走字节级替换，不重编码其它内容', () async {
      final path = p.join(sandbox.path, 'latin1.bin');
      File(path).writeAsBytesSync([0x61, 0xE9, 0x62, 0x0A]);
      final r = await _run(LocalFilePatchTool(), {
        'path': path,
        'old_b64': base64Encode([0x61, 0xE9, 0x62]),
        'new_b64': base64Encode([0x61, 0xE9, 0x63]),
        'backup': false,
      });
      expect(r.success, isTrue, reason: r.error);
      expect(File(path).readAsBytesSync(), [0x61, 0xE9, 0x63, 0x0A]);
    });

    test('非截断打开后策略撤销则回滚且不改写目标', () async {
      final path = sandboxFile('opened-policy-change.txt', 'original');
      var current = LocalFilePolicy(enabled: true, allowedDirs: [sandbox.path]);
      // 用共享原语精确控制授权回调发生的时机。
      final outcome = await writeLocalFile(
        path: path,
        bytes: utf8.encode('replacement'),
        authorizePath: (_, __) async =>
            current.allowedDirs.isNotEmpty ? null : '授权已撤销',
        authorizeOpenedWrite: (_) async {
          current = const LocalFilePolicy(enabled: true, allowedDirs: []);
          return '授权已撤销';
        },
      );
      expect(outcome.success, isFalse);
      expect(outcome.error, contains('授权已撤销'));
      expect(File(path).readAsStringSync(), 'original');
    });

    test('patch 非截断打开后父目录被替换则 fail-closed', () async {
      if (Platform.isWindows) return;
      final parent = Directory(p.join(sandbox.path, 'swap-parent'))
        ..createSync();
      final target = File(p.join(parent.path, 'target.txt'))
        ..writeAsStringSync('original');
      final moved = Directory(p.join(sandbox.path, 'moved-parent'));
      final outsideParent = Directory(p.join(outside.path, 'outside-parent'))
        ..createSync();
      final outsideFile = File(p.join(outsideParent.path, 'target.txt'))
        ..writeAsStringSync('outside-original');
      var swapped = false;
      final outcome = await patchLocalFile(
        path: target.path,
        oldText: 'original',
        newText: 'replacement',
        backup: false,
        authorizePath: (rawPath, expected) async {
          final decision = LocalFilePolicy.load().decide(rawPath);
          if (!decision.isAllowed) return decision.reason;
          if (p.normalize(decision.resolved) != p.normalize(expected)) {
            return '路径身份已变化';
          }
          return null;
        },
        authorizeOpenedWrite: (_) async {
          if (!swapped) {
            swapped = true;
            parent.renameSync(moved.path);
            Link(parent.path).createSync(outsideParent.path);
          }
          return null;
        },
      );
      expect(swapped, isTrue);
      expect(outcome.success, isFalse);
      expect(outcome.error, contains('授权'));
      expect(
          File(p.join(moved.path, 'target.txt')).readAsStringSync(), 'original',
          reason: '已打开的原句柄内容必须保持原样');
      expect(outsideFile.readAsStringSync(), 'outside-original',
          reason: '父目录替换不得写到白名单外目标');
    });

    test('backup: false 时不留备份', () async {
      final path = sandboxFile('nb.txt', 'old');
      final r = await _run(LocalFileWriteTool(),
          {'path': path, 'content': 'new', 'backup': false});
      expect(r.success, isTrue);
      expect(r.output, isNot(contains('已备份')));
    });

    test('patch 要求 old 唯一；0 次与多次都失败且不改动文件', () async {
      final path = sandboxFile('p.conf', 'listen 80;\nlisten 80;\n');
      final dup = await _run(LocalFilePatchTool(),
          {'path': path, 'old': 'listen 80;', 'new': 'listen 8080;'});
      expect(dup.success, isFalse);
      expect(dup.error, contains('出现 2 次'));
      expect(File(path).readAsStringSync(), contains('listen 80;'));

      final none = await _run(LocalFilePatchTool(),
          {'path': path, 'old': 'server_name x;', 'new': 'y'});
      expect(none.success, isFalse);
      expect(none.error, contains('未找到'));

      final ok = await _run(LocalFilePatchTool(), {
        'path': path,
        'old': 'listen 80;\nlisten 80;',
        'new': 'listen 8080;',
      });
      expect(ok.success, isTrue, reason: '更长上下文使其唯一');
      expect(File(path).readAsStringSync(), 'listen 8080;\n');
    });

    test('patch 用 base64 传多行内容', () async {
      final path = sandboxFile('b64.txt', 'line one\nline two');
      final r = await _run(LocalFilePatchTool(), {
        'path': path,
        'old_b64': base64Encode(utf8.encode('line one')),
        'new_b64': base64Encode(utf8.encode('LINE 一')),
      });
      expect(r.success, isTrue);
      expect(File(path).readAsStringSync(), 'LINE 一\nline two');
    });

    test('patch 二进制文件给出可读错误而不是崩', () async {
      final bin = File('${sandbox.path}/bin.bin')
        ..writeAsBytesSync([0, 159, 146, 250]);
      final before = bin.readAsBytesSync();
      final r = await _run(
          LocalFilePatchTool(), {'path': bin.path, 'old': 'x', 'new': 'y'});
      expect(r.success, isFalse);
      expect(r.error, isNotNull);
      expect(bin.readAsBytesSync(), before, reason: '读取或校验失败不得截断原文件');
    });
  });

  group('local_file_move / delete', () {
    test('move 默认不覆盖，overwrite 才替换', () async {
      final src = sandboxFile('src.txt', 'src');
      final dst = sandboxFile('dst.txt', 'dst');
      final refused =
          await _run(LocalFileMoveTool(), {'path': src, 'dst': dst});
      expect(refused.success, isFalse);
      expect(refused.error, contains('目标已存在'));
      expect(File(src).existsSync(), isTrue, reason: '被拒绝时不得动源文件');

      final forced = await _run(
          LocalFileMoveTool(), {'path': src, 'dst': dst, 'overwrite': true});
      expect(forced.success, isTrue);
      expect(File(src).existsSync(), isFalse);
      expect(File(dst).readAsStringSync(), 'src');
    });

    test('move 覆盖失败时恢复原目标且不丢源文件', () async {
      final src = sandboxFile('restore-src.txt', 'source');
      final dst = sandboxFile('restore-dst.txt', 'original');
      var active = true;
      var policyReads = 0;
      final tool = LocalFileMoveTool(policyLoader: () {
        policyReads++;
        if (policyReads == 5) active = false;
        return LocalFilePolicy(enabled: true, allowedDirs: [sandbox.path]);
      })
        ..localAccess = LocalAccessService(
          taskId: 'move-restore',
          generation: 1,
          isActive: () => active,
        );

      final result =
          await _run(tool, {'path': src, 'dst': dst, 'overwrite': true});

      expect(result.success, isFalse);
      expect(result.error, contains('授权状态已变化'));
      expect(File(src).readAsStringSync(), 'source');
      expect(File(dst).readAsStringSync(), 'original');
      expect(
        sandbox.listSync().where((entity) =>
            p.basename(entity.path).startsWith('.ai_terminal_overwrite_')),
        isEmpty,
      );
    });

    test('move 到白名单外被拒绝', () async {
      final src = sandboxFile('s.txt', 'x');
      final r = await _run(
          LocalFileMoveTool(), {'path': src, 'dst': '${outside.path}/s.txt'});
      expect(r.success, isFalse);
    });

    test('delete 默认移入回收区，可还原', () async {
      final path = sandboxFile('gone.txt', 'content');
      final r = await _run(LocalFileDeleteTool(), {'path': path});
      expect(r.success, isTrue);
      expect(r.output, contains('回收区'));
      expect(File(path).existsSync(), isFalse);
      final trash = Directory('${sandbox.path}/.ai_terminal_trash');
      expect(trash.existsSync(), isTrue);
      final moved = trash
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('gone.txt'));
      expect(moved, isNotEmpty, reason: '内容留在回收区，台账回滚就是把它移回原位');
      expect(moved.first.readAsStringSync(), 'content');
    });

    test('delete 目录需要 recursive；hard 才真删', () async {
      Directory('${sandbox.path}/d').createSync();
      File('${sandbox.path}/d/inner.txt').writeAsStringSync('i');
      final noRecurse =
          await _run(LocalFileDeleteTool(), {'path': '${sandbox.path}/d'});
      expect(noRecurse.success, isFalse);
      expect(noRecurse.error, contains('recursive'));

      final hard = await _run(LocalFileDeleteTool(),
          {'path': '${sandbox.path}/d', 'recursive': true, 'hard': true});
      expect(hard.success, isTrue);
      expect(Directory('${sandbox.path}/d').existsSync(), isFalse);
    });

    test('delete 未授权路径被拒绝', () async {
      final victim = File('${outside.path}/v.txt')..writeAsStringSync('v');
      final r = await _run(LocalFileDeleteTool(), {'path': victim.path});
      expect(r.success, isFalse);
      expect(victim.existsSync(), isTrue);
    });

    test('回收区符号链接不能把删除文件转移到授权目录外', () async {
      if (Platform.isWindows) return;
      final path = sandboxFile('trash-link-victim.txt', 'keep');
      final link = Link('${sandbox.path}/.ai_terminal_trash');
      try {
        link.createSync(outside.path);
      } on FileSystemException {
        return;
      }

      final result = await _run(LocalFileDeleteTool(), {'path': path});

      expect(result.success, isFalse);
      expect(result.error, contains('符号链接'));
      expect(File(path).readAsStringSync(), 'keep');
      expect(outside.listSync(), isEmpty);
    });

    test('递归删除前发现目录内符号链接则拒绝', () async {
      if (Platform.isWindows) return;
      final dir = Directory('${sandbox.path}/linked-tree')..createSync();
      File('${dir.path}/inside.txt').writeAsStringSync('inside');
      final outsideFile = File('${outside.path}/outside.txt')
        ..writeAsStringSync('outside');
      try {
        Link('${dir.path}/escape').createSync(outsideFile.path);
      } on FileSystemException {
        return;
      }

      final result = await _run(LocalFileDeleteTool(), {
        'path': dir.path,
        'recursive': true,
        'hard': true,
      });

      expect(result.success, isFalse);
      expect(result.error, contains('符号链接'));
      expect(File('${dir.path}/inside.txt').readAsStringSync(), 'inside');
      expect(outsideFile.readAsStringSync(), 'outside');
    });

    test('回收区是保留目录：AI 不能读、改、再删', () async {
      // 先造一次真实删除，让回收区里确实有可回滚的副本
      final path = sandboxFile('target.txt', 'recoverable');
      final deleted = await _run(LocalFileDeleteTool(), {'path': path});
      expect(deleted.success, isTrue);
      final trash = Directory('${sandbox.path}/.ai_terminal_trash');
      expect(trash.existsSync(), isTrue);
      final copy = trash
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('target.txt'));

      // "删了还能捞回来"这个承诺依赖这份副本不被二次破坏
      expect((await _run(LocalFileReadTool(), {'path': copy.path})).success,
          isFalse);
      expect(
        (await _run(LocalFileWriteTool(),
                {'path': copy.path, 'content': 'clobbered'}))
            .success,
        isFalse,
      );
      expect((await _run(LocalFileDeleteTool(), {'path': copy.path})).success,
          isFalse);
      expect((await _run(LocalDirListTool(), {'path': trash.path})).success,
          isFalse);
      expect(copy.readAsStringSync(), 'recoverable', reason: '副本必须原样还在');
    });

    test('嵌套一层的回收区同样是保留目录', () async {
      // 回收区跟着被删文件的目录走，所以它可能出现在授权根的任意深度。
      // 保留判定必须是"路径段里出现 .ai_terminal_trash 就拒"，只看根一层会漏。
      final nested =
          sandboxFile(p.join('sub', 'deep', 'victim.txt'), 'nested-copy');
      final deleted = await _run(LocalFileDeleteTool(), {'path': nested});
      expect(deleted.success, isTrue);

      final nestedTrash =
          Directory(p.join(sandbox.path, 'sub', 'deep', '.ai_terminal_trash'));
      expect(nestedTrash.existsSync(), isTrue, reason: '副本落在文件自己所在目录旁');
      final copy = nestedTrash
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('victim.txt'));

      expect((await _run(LocalFileReadTool(), {'path': copy.path})).success,
          isFalse);
      expect(
        (await _run(LocalFileDeleteTool(), {'path': copy.path})).success,
        isFalse,
      );
      expect(
        (await _run(LocalDirListTool(), {'path': nestedTrash.path})).success,
        isFalse,
      );
      expect(copy.readAsStringSync(), 'nested-copy');
    });

    test('删除工具自身仍能写回收区（保留目录不挡内部 rename）', () async {
      final a = sandboxFile('a.txt', 'A');
      final b = sandboxFile('b.txt', 'B');
      expect((await _run(LocalFileDeleteTool(), {'path': a})).success, isTrue);
      // 第二次删除要能建出新的时间戳子目录，说明 rename 进回收区没被挡
      expect((await _run(LocalFileDeleteTool(), {'path': b})).success, isTrue);
      final trash = Directory('${sandbox.path}/.ai_terminal_trash');
      expect(
        trash.listSync().whereType<Directory>().length,
        greaterThanOrEqualTo(2),
      );
    });
  });

  group('LocalFilePolicy 持久化往返', () {
    // 这个往返是我把存储从 JSON 字符串改成 Map 之后唯一没被覆盖到的环节：
    // SettingsDao.set 会 jsonEncode，loadAll 会 jsonDecode，形状对不上就会
    // 静默退化成"未授权" —— 用户加了目录但工具说没加，且没有任何报错。
    test('save 后 load 能读回同样的配置', () async {
      final policy = LocalFilePolicy(
        enabled: true,
        allowedDirs: [r'D:\proj\a', r'D:\proj\b'],
        maxReadBytes: 4096,
      );
      await policy.save();
      final back = LocalFilePolicy.load();
      expect(back.enabled, isTrue);
      expect(back.allowedDirs, [r'D:\proj\a', r'D:\proj\b']);
      expect(back.maxReadBytes, 4096);
    });

    test('经过 JSON 编解码（真实落库路径）后仍等价', () {
      final policy = LocalFilePolicy(
        enabled: true,
        allowedDirs: ['/srv/www', '/tmp/x'],
        maxReadBytes: 1234,
      );
      final stored = jsonEncode(policy.toMap());
      final restored =
          LocalFilePolicy.fromMap(jsonDecode(stored) as Map<String, dynamic>);
      expect(restored.enabled, isTrue);
      expect(restored.allowedDirs, ['/srv/www', '/tmp/x']);
      expect(restored.maxReadBytes, 1234);
    });

    test('未配置时默认关闭且无授权目录，decide 拒绝访问', () async {
      await SettingsDao.set('localFilePolicy', null);
      final policy = LocalFilePolicy.load();
      expect(policy.enabled, isFalse);
      expect(policy.allowedDirs, isEmpty);
      expect(
          policy.decide(p.join(outside.path, 'open.txt')).isAllowed, isFalse);
    });

    test('配置形状无效时 fail-closed，不开放本地文件', () async {
      await SettingsDao.set('localFilePolicy', 'not-a-map');
      final policy = LocalFilePolicy.load();
      expect(policy.enabled, isFalse, reason: '解析失败不能当成 enabled=true');
      expect(policy.allowedDirs, isEmpty);
      expect(
          policy.decide(p.join(outside.path, 'open.txt')).isAllowed, isFalse);
    });

    test('授权目录或读取上限形状损坏时 fail-closed', () async {
      for (final malformed in [
        {'enabled': true, 'allowedDirs': 'not-a-list'},
        {
          'enabled': true,
          'allowedDirs': [123]
        },
        {
          'enabled': true,
          'allowedDirs': [sandbox.path],
          'maxReadBytes': -1
        },
      ]) {
        await SettingsDao.set('localFilePolicy', malformed);
        final policy = LocalFilePolicy.load();
        expect(policy.enabled, isFalse);
        expect(policy.decide(p.join(sandbox.path, 'a.txt')).isAllowed, isFalse);
      }
    });
  });

  group('设置页授权区', () {
    // AgentUiText 按 locale 出中/英文，不设 locale 会拿到英文文案
    Widget wrap(Widget child) => MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: child)),
        );

    testWidgets('开关拨动会真的落库，工具随后就能读', (tester) async {
      await _configurePolicy(enabled: false, dirs: []);

      await tester.pumpWidget(wrap(const LocalFileAccessSection()));
      await tester.pump();

      var toggle = find.byType(Switch);
      expect(toggle, findsOneWidget);
      expect(tester.widget<Switch>(toggle).value, isFalse);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(LocalFilePolicy.load().enabled, isTrue,
          reason: 'UI 状态必须落到策略本身，否则页面显示已开启而工具仍然全拒');
    });

    testWidgets('未授权目录时给出明确空态与黑名单提示', (tester) async {
      await _configurePolicy(enabled: true, dirs: []);
      await tester.pumpWidget(wrap(const LocalFileAccessSection()));
      await tester.pump();

      expect(find.textContaining('还没有授权目录'), findsOneWidget);
      expect(find.textContaining('添加目录'), findsOneWidget);
      expect(find.textContaining('.ssh'), findsOneWidget,
          reason: '必须说明即使授权了目录，密钥类文件仍被禁止');
    });

    testWidgets('回收区为空时只报空态，不给清空按钮', (tester) async {
      // 台账缓存在测试里是空的，正好覆盖"没有回收条目"这一支：
      // 用量行必须出现（否则用户不知道有这回事），但清空按钮不该出现
      await _configurePolicy(enabled: true, dirs: []);
      await tester.pumpWidget(wrap(const LocalFileAccessSection()));
      await tester.pump();

      expect(find.text('回收区为空'), findsOneWidget);
      expect(find.text('清空回收区'), findsNothing);
    });

    testWidgets('已授权目录逐条列出且可移除', (tester) async {
      await _configurePolicy(enabled: true, dirs: [sandbox.path]);
      await tester.pumpWidget(wrap(const LocalFileAccessSection()));
      await tester.pump();

      expect(find.text(sandbox.path), findsOneWidget);
      expect(find.text('还没有授权目录'), findsNothing);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(LocalFilePolicy.load().allowedDirs, isEmpty);
      expect(find.text('还没有授权目录'), findsOneWidget);
    });
  });

  group('注册与元数据', () {
    test('7 个本地文件工具都注册且默认作用域可见', () {
      final registry = AgentToolRegistry();
      for (final isLocal in [true, false]) {
        final names =
            registry.visibleFor(isLocalSession: isLocal).map((t) => t.name);
        expect(
          names,
          containsAll([
            'local_file_read',
            'local_dir_list',
            'local_file_search',
            'local_file_write',
            'local_file_patch',
            'local_file_move',
            'local_file_delete',
          ]),
        );
      }
    });

    test('kind 标注正确：读类只读，delete 是破坏性', () {
      final registry = AgentToolRegistry();
      expect(registry.get('local_file_read')!.kind, ToolKind.read);
      expect(registry.get('local_dir_list')!.kind, ToolKind.read);
      expect(registry.get('local_file_search')!.kind, ToolKind.read);
      expect(registry.get('local_file_write')!.kind, ToolKind.write);
      expect(registry.get('local_file_delete')!.kind, ToolKind.destructive);
      // 写类必须进台账，才谈得上回滚
      expect(registry.isChangeRecordingTool('local_file_write'), isTrue);
      expect(registry.isChangeRecordingTool('local_file_delete'), isTrue);
      expect(registry.isChangeRecordingTool('local_file_read'), isFalse);
    });
  });

  group('还原对（工具 → 台账 → 回滚 的衔接点）', () {
    test('delete 报告回收位置与放回路径', () async {
      final path = sandboxFile('gone2.txt', 'x');
      final r = await _run(LocalFileDeleteTool(), {'path': path});
      expect(r.restoreFrom, isNotNull);
      expect(r.restoreTo, path);
      expect(File(r.restoreFrom!).existsSync(), isTrue,
          reason: '还原对里的副本必须真实存在，否则台账上的"可回滚"是假的');
      expect(r.restoreFrom, contains(LocalFilePolicy.trashDirName));
    });

    test('write 覆盖时报告备份位置', () async {
      final path = sandboxFile('w.txt', 'old');
      final r =
          await _run(LocalFileWriteTool(), {'path': path, 'content': 'new'});
      expect(r.restoreFrom, isNotNull);
      expect(r.restoreTo, path);
      expect(File(r.restoreFrom!).readAsStringSync(), 'old');
    });

    test('write 新建文件没有可回滚对象，还原对为空', () async {
      final path = '${sandbox.path}/brand-new.txt';
      final r =
          await _run(LocalFileWriteTool(), {'path': path, 'content': 'x'});
      expect(r.success, isTrue);
      expect(r.restoreFrom, isNull);
      expect(r.restoreTo, isNull);
    });

    test('patch 报告备份位置', () async {
      final path = sandboxFile('p2.txt', 'listen 80;');
      final r = await _run(LocalFilePatchTool(),
          {'path': path, 'old': 'listen 80;', 'new': 'listen 90;'});
      expect(r.restoreFrom, isNotNull);
      expect(r.restoreTo, path);
      expect(File(r.restoreFrom!).readAsStringSync(), 'listen 80;');
    });

    test('move 报告"从新位置移回原位置"', () async {
      final src = sandboxFile('m1.txt', 'data');
      final dst = p.join(sandbox.path, 'm2.txt');
      final r = await _run(LocalFileMoveTool(), {'path': src, 'dst': dst});
      expect(p.normalize(r.restoreFrom!), p.normalize(dst));
      expect(p.normalize(r.restoreTo!), p.normalize(src));
    });
  });

  group('本机/远程路径混淆防护', () {
    // 设计稿 §4 预言的混淆："两套工具名相近，AI 极易拿 local_file_write 去写
    // /var/www/..."，反过来也一样。反向那一半之前没实现：在 SSH 会话里给
    // file_write 一个 `D:\deploy\app.conf`，SFTP 会把整串当成服务器上的
    // 文件名写下去并回报成功 —— 一次静默的错机器写入。
    SSHService sshSession() => SSHService(HostConfig.create(
          id: 'guard-test',
          name: 'Guard Test',
          host: '127.0.0.1',
          port: 22,
          username: 'root',
          authType: 'password',
        ));

    test('SSH 会话里 file_write 收到本机路径会被拦下', () async {
      final r = await FileWriteTool().execute(
        executor: sshSession(),
        args: const ToolArgs({'path': r'D:\deploy\app.conf', 'content': 'x'}),
      );
      expect(r.success, isFalse);
      expect(r.error, contains('local_file_write'));
      expect(r.error, isNot(contains('SSH 连接未建立')),
          reason: '守卫必须建连之前就说明白，而不是报一个不相干的连接错');
    });

    test('SSH 会话里 file_patch 同样拦本机路径', () async {
      final r = await FilePatchTool().execute(
        executor: sshSession(),
        args: const ToolArgs(
            {'path': r'D:\deploy\app.conf', 'old': 'a', 'new': 'b'}),
      );
      expect(r.success, isFalse);
      expect(r.error, contains('local_file_patch'));
    });

    test('正常的远程路径不被形状判定误伤', () async {
      final r = await FileWriteTool().execute(
        executor: sshSession(),
        args: const ToolArgs({'path': '/etc/nginx/nginx.conf', 'content': 'x'}),
      );
      expect(r.error, contains('SSH 连接未建立'),
          reason: '应该走到连接检查，说明 /etc/... 没被当成本机路径拦掉');
    });

    test('本机工具收到远程风格路径时指路远程工具', () async {
      final r =
          await _run(LocalFileReadTool(), {'path': '/etc/nginx/nginx.conf'});
      expect(r.success, isFalse);
      if (Platform.isWindows) {
        // 只有 Windows 本机才存在这种歧义：macOS/Linux 的本地路径本来就是 / 开头
        expect(r.error, contains('看起来是远程主机的路径'));
        expect(r.error, contains('file_write'));
      } else {
        expect(r.error ?? '', isNot(contains('看起来是远程主机的路径')),
            reason: '在 POSIX 本机上加这条提示会把合法路径也说成远程');
      }
    });

    test('敏感目录的拒绝不附带远程指路', () async {
      // 黑名单/保留目录的拒绝本身是对的，附一句"也许你想要远程工具"
      // 等于教 AI 换个工具绕过黑名单
      final r = await _run(LocalFileReadTool(), {'path': '/root/.ssh/id_rsa'});
      expect(r.success, isFalse);
      expect(r.error ?? '', isNot(contains('看起来是远程主机的路径')));
    });
  });

  test('file_sync 启动前必须通过本地目录白名单', () async {
    // 同步会持续读本地文件并往本地写下载结果，不能绕过 local_* 的路径策略。
    final tool = FileSyncTool(FileSyncService());
    final r = await _run(tool, {
      'action': 'start',
      'localDir': outside.path,
      'remoteDir': '/tmp/story',
    });
    expect(r.success, isFalse);
    expect(r.error, contains('本地路径未获授权'));
  });

  test('file_sync 服务已释放后拒绝启动，避免泄漏 watcher/timer', () async {
    // disposeTools 可能在工具等待授权期间执行；释放后不能再挂新资源。
    final service = FileSyncService()..dispose();
    final started = await service.start(
      clientGetter: () => null,
      config: SyncConfig(localDir: outside.path, remoteDir: '/tmp/story'),
    );
    expect(started, isFalse);
    expect(service.isRunning, isFalse);
  });
}
