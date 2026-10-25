import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/core/l10n_holder.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/agent_memory.dart';
import 'package:ai_terminal/models/ai_model_config.dart';
import 'package:ai_terminal/models/chat_session.dart';
import 'package:ai_terminal/models/host_config.dart';
import 'package:ai_terminal/services/agent_engine.dart';
import 'package:ai_terminal/services/ai_service.dart';
import 'package:ai_terminal/services/sftp_service.dart';
import 'package:ai_terminal/services/ssh_service.dart';

class _ScriptedAI implements AIProvider {
  final List<String> _responses;
  int _index = 0;

  _ScriptedAI(this._responses);

  @override
  Future<Stream<String>> chatStream({
    required List<ChatMessage> history,
    required String prompt,
    required AIModelConfig config,
    String? systemPrompt,
    CancelToken? cancelToken,
    List<Map<String, dynamic>>? tools,
  }) async {
    if (_index >= _responses.length) {
      throw StateError('No scripted response left (call=${_index + 1})');
    }
    return Stream<String>.value(_responses[_index++]);
  }
}

final _env = Platform.environment;
final _sshHost = _env['E2E_SSH_HOST'];
final _sshUser = _env['E2E_SSH_USER'];
final _sshPassword = _env['E2E_SSH_PASSWORD'];
final _sshPort = int.tryParse(_env['E2E_SSH_PORT'] ?? '') ?? 22;
final _sshEnabled = _sshHost?.isNotEmpty == true &&
    _sshUser?.isNotEmpty == true &&
    _sshPassword != null;
const _skipReason =
    'Set E2E_SSH_HOST / E2E_SSH_PORT / E2E_SSH_USER / E2E_SSH_PASSWORD to run';

String _b64(String text) => base64Encode(utf8.encode(text));

String _writeTool(String path, String content, {String mode = 'write'}) {
  return '思考: 写入文件\n动作: tool\n工具: file_write\n参数:\n'
      '  path: $path\n'
      '  content_b64: ${_b64(content)}\n'
      '  mode: $mode\n'
      '  backup: false\n';
}

String _patchTool(String path, String oldText, String newText) {
  return '思考: 修改文件\n动作: tool\n工具: file_patch\n参数:\n'
      '  path: $path\n'
      '  old_b64: ${_b64(oldText)}\n'
      '  new_b64: ${_b64(newText)}\n'
      '  backup: false\n';
}

Future<Uint8List> _readBytes(SSHService ssh, String path) async {
  final sftp = SftpService();
  await sftp.attachToClient(ssh.client!);
  try {
    return await sftp.readFileBytes(path);
  } finally {
    sftp.closeSftpOnly();
  }
}

void main() {
  setUpAll(() {
    if (!L10n.isReady) L10n.setup(AppLocalizationsZh());
  });

  group('File encoding E2E', skip: _sshEnabled ? false : _skipReason, () {
    test('file_write/file_patch/append/PTY/heredoc preserve UTF-8 bytes',
        () async {
      final ssh = SSHService(HostConfig.create(
        id: 'file-encoding-e2e',
        name: 'File Encoding E2E',
        host: _sshHost!,
        port: _sshPort,
        username: _sshUser!,
        authType: 'password',
      ));
      var connected = false;
      const dir = '/tmp/ai_terminal_encoding_e2e';
      const basePath = '$dir/base.txt';
      const crlfPath = '$dir/crlf.txt';
      const noTrailingPath = '$dir/no_trailing.txt';
      const largePath = '$dir/large.txt';
      const ptyPath = '$dir/pty.txt';
      const ptyNoTrailingPath = '$dir/pty_no_trailing.txt';
      const shellPath = '$dir/shell.txt';

      const tab = '\t';
      final baseContent = '第一行：中文测试\n'
          '第二行：emoji 😀🚀\n'
          '第三行：特殊字符 \$HOME `whoami` "double" \'single\' \\backslash & | ; > %\n'
          '第四行：制表符${tab}结尾空格  \n'
          '第五行：LF\n';
      const patchOld = '第二行：emoji 😀🚀';
      const patchNew = '第二行：已修改 😀✅';
      const appendContent = '追加：中文✅\n';
      const crlfContent = '第一行\r\n第二行中文\r\n';
      const noTrailingContent = '无尾换行：中文✅';
      final largeChunk1 = '中' * 2500;
      final largeChunk2 = '文' * 500;
      const ptyContent = 'PTY 中文 😀\n'
          '第二行 \$HOME `whoami` "x" \'y\' \\z\tTab\r\n';
      const ptyNoTrailing = 'PTY 无尾换行 中文✅';
      const shellContent = 'Heredoc 中文 😀\n'
          '\$HOME `whoami` "double" \'single\' \\backslash';

      try {
        await ssh.connect(password: _sshPassword!);
        expect(ssh.isConnected, isTrue);
        connected = true;
        await ssh.executeAndWait('mkdir -p $dir');

        final expectedBase =
            baseContent.replaceFirst(patchOld, patchNew) + appendContent;
        final provider = _ScriptedAI([
          _writeTool(basePath, baseContent),
          _patchTool(basePath, patchOld, patchNew),
          _writeTool(basePath, appendContent, mode: 'append'),
          _writeTool(crlfPath, crlfContent),
          _writeTool(noTrailingPath, noTrailingContent),
          _writeTool(largePath, largeChunk1),
          _writeTool(largePath, largeChunk2, mode: 'append'),
          '思考: 结论: 文件编码测试完成\n现状: 所有文件写入成功\n'
              '变更: 写入并修改了测试文件\n建议: 无\n动作: finish\n',
        ]);
        final engine = AgentEngine(
          aiProvider: provider,
          modelConfig: AIModelConfig.create(
            id: 'file-encoding-e2e',
            provider: 'openai',
            name: 'File Encoding E2E',
            apiKey: 'test-key',
            baseUrl: 'http://127.0.0.1/v1',
            modelName: 'e2e',
          ),
          memory: AgentMemory(),
          maxSteps: 12,
          hostId: 'file-encoding-e2e',
        );
        final events = <AgentEvent>[];
        engine.onEvent = events.add;

        await engine.startTask('写入并修改编码测试文件', ssh);

        final report = events
            .where((e) => e.isReport)
            .single
            .operationReport!;
        expect(report.finishState, 'success');
        final results = events.where((e) => e.isResult).toList();
        expect(results, isNotEmpty);
        expect(results.every((e) => e.success == true), isTrue);

        final patchResult = results.firstWhere(
          (e) => e.toolName == 'file_patch',
        );
        expect(patchResult.diffAdditions, 1);
        expect(patchResult.diffDeletions, 1);

        expect(await _readBytes(ssh, basePath), utf8.encode(expectedBase));
        expect(await _readBytes(ssh, crlfPath), utf8.encode(crlfContent));
        expect(await _readBytes(ssh, noTrailingPath),
            utf8.encode(noTrailingContent));
        expect(await _readBytes(ssh, largePath),
            utf8.encode(largeChunk1 + largeChunk2));

        // PTY stdin 路径（file_write 的 SFTP fallback 同样走这里）
        final pty = await ssh.writeFileViaPty(
          path: ptyPath,
          content: Uint8List.fromList(utf8.encode(ptyContent)),
        );
        expect(pty.success, isTrue);
        expect(await _readBytes(ssh, ptyPath), utf8.encode(ptyContent));

        final ptyNoNl = await ssh.writeFileViaPty(
          path: ptyNoTrailingPath,
          content: Uint8List.fromList(utf8.encode(ptyNoTrailing)),
        );
        expect(ptyNoNl.success, isTrue);
        expect(await _readBytes(ssh, ptyNoTrailingPath),
            utf8.encode(ptyNoTrailing));

        // 引号 heredoc 路径（AI 常用写法）：$ 和反引号不应展开
        final heredoc = "cat > '$shellPath' <<'AI_TERMINAL_EOF'\n"
            '$shellContent\n'
            'AI_TERMINAL_EOF';
        final heredocResult = await ssh.executeAndWait(heredoc);
        expect(heredocResult.success, isTrue);
        expect(await _readBytes(ssh, shellPath),
            utf8.encode('$shellContent\n'));
      } finally {
        if (connected) {
          try {
            await ssh.executeAndWait('rm -rf $dir');
          } catch (_) {}
        }
        await ssh.disconnect();
      }
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}
