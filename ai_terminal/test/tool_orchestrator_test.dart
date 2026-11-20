import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/agent_permission_mode.dart';
import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/services/command_executor.dart';
import 'package:ai_terminal/services/tool_orchestrator.dart';
import 'package:ai_terminal/utils/tool_args_parser.dart';

/// Step 6 特征化测试：锁定 `ToolOrchestrator` 从引擎抽出时的原始语义，
/// 防止后续再拆分时把「别名路由 / 门禁顺序 / 截断阈值」改掉。
///
/// 这些断言不涉及引擎私有状态 —— 需要状态的部分（确认握手、状态切换、
/// 重试计数与终态收口）仍由 `agent_engine` 的集成测试覆盖。
void main() {
  ToolArgs argsOf(Map<String, dynamic> raw) => ToolArgs(raw);

  group('ToolArgNormalizer', () {
    test('唯一键且为 Map 时解包嵌套 args', () {
      final out = ToolArgNormalizer.unwrapNestedArgs({
        'args': {'path': '/tmp/a', 'content': 'hi'},
      });
      expect(out, {'path': '/tmp/a', 'content': 'hi'});
    });

    test('多键时不解包（正常平铺参数不会被误伤）', () {
      final raw = {
        'args': {'path': '/tmp/a'},
        'timeout': 5,
      };
      expect(ToolArgNormalizer.unwrapNestedArgs(raw), same(raw));
    });

    test('args 不是 Map 时原样返回', () {
      final raw = {'args': 'not-a-map'};
      expect(ToolArgNormalizer.unwrapNestedArgs(raw), same(raw));
    });

    test('空参数原样返回', () {
      final raw = <String, dynamic>{};
      expect(ToolArgNormalizer.unwrapNestedArgs(raw), same(raw));
    });

    test('嵌套 Map 的键统一转成 String', () {
      final out = ToolArgNormalizer.unwrapNestedArgs({
        'args': {1: 'a'},
      });
      expect(out, {'1': 'a'});
    });
  });

  group('ToolAliasRouter', () {
    test('think 别名提取 thought', () {
      final route = ToolAliasRouter.resolve(
        'think',
        argsOf({'thought': '先看一下目录'}),
      );
      expect(route.kind, ToolAliasKind.think);
      expect(route.hasThought, isTrue);
      expect(route.thought, '先看一下目录');
    });

    test('think 别名没有思考参数时 hasThought=false', () {
      final route = ToolAliasRouter.resolve('thinking', argsOf({}));
      expect(route.kind, ToolAliasKind.think);
      expect(route.hasThought, isFalse);
    });

    test('think 别名即便带 command 也只按思考处理', () {
      final route = ToolAliasRouter.resolve(
        'reason',
        argsOf({'command': 'ls'}),
      );
      expect(route.kind, ToolAliasKind.think);
      expect(route.hasCommand, isFalse);
    });

    test('execute 别名大小写不敏感并提取 command', () {
      final route = ToolAliasRouter.resolve(
        'Execute',
        argsOf({'command': 'ls -la'}),
      );
      expect(route.kind, ToolAliasKind.execute);
      expect(route.command, 'ls -la');
    });

    test('命令字段按优先级回落（command 缺省取 cmd）', () {
      final route = ToolAliasRouter.resolve(
        'shell',
        argsOf({'cmd': 'pwd', 'script': 'whoami'}),
      );
      expect(route.kind, ToolAliasKind.execute);
      expect(route.command, 'pwd');
    });

    test('占位名同时给出命令与思考时按命令路由', () {
      final route = ToolAliasRouter.resolve(
        'function_name',
        argsOf({'command': 'df -h', 'thought': '看磁盘'}),
      );
      expect(route.kind, ToolAliasKind.placeholder);
      expect(route.hasCommand, isTrue);
      expect(route.command, 'df -h');
    });

    test('占位名没有命令时保留思考文本', () {
      final route = ToolAliasRouter.resolve(
        'tool_call',
        argsOf({'note': '先想一下'}),
      );
      expect(route.kind, ToolAliasKind.placeholder);
      expect(route.hasCommand, isFalse);
      expect(route.hasThought, isTrue);
    });

    test('普通工具名不命中任何别名', () {
      final route = ToolAliasRouter.resolve('file_write', argsOf({}));
      expect(route.kind, ToolAliasKind.notAlias);
    });
  });

  group('ToolDisplayFormatter', () {
    test('空参数只返回工具名', () {
      expect(ToolDisplayFormatter.describe('file_read', argsOf({})), 'file_read');
    });

    test('多行 key:value 格式且无尾随换行', () {
      final out = ToolDisplayFormatter.describe(
        'file_write',
        argsOf({'path': '/tmp/a', 'content': 'hi'}),
      );
      expect(out, 'file_write\n  path: /tmp/a\n  content: hi');
    });

    test('List 参数按逗号拼接', () {
      final out = ToolDisplayFormatter.describe(
        'multi_grep',
        argsOf({
          'patterns': ['a', 'b'],
        }),
      );
      expect(out, contains('patterns: a,b'));
    });

    test('maxValueChars 截断并标注原长度', () {
      final out = ToolDisplayFormatter.describe(
        'file_write',
        argsOf({'content': 'x' * 10}),
        maxValueChars: 4,
      );
      expect(out, contains('content: xxxx… (10 字符)'));
    });

    test('默认不截断', () {
      final long = 'y' * 500;
      final out = ToolDisplayFormatter.describe(
        'file_write',
        argsOf({'content': long}),
      );
      expect(out, contains(long));
      expect(out, isNot(contains('字符)')));
    });
  });

  group('ToolResultPresenter', () {
    test('成功取 output 且不截断', () {
      final view = ToolResultPresenter.fromResult(ToolResult.success('ok'));
      expect(view.text, 'ok');
      expect(view.displayed, 'ok');
      expect(view.truncated, isFalse);
      expect(view.totalChars, 2);
    });

    test('失败优先取 error', () {
      final view = ToolResultPresenter.fromResult(
        ToolResult.failure('boom', output: 'partial'),
      );
      expect(view.text, 'boom');
      expect(view.totalChars, 4);
    });

    test('失败且没有 error 时回落到 output', () {
      final view = ToolResultPresenter.fromResult(
        const ToolResult(success: false, output: 'stderr only'),
      );
      expect(view.text, 'stderr only');
    });

    test('超过 8000 字符时截断并加尾注', () {
      final long = 'z' * (ToolResultPresenter.maxEventChars + 10);
      final view = ToolResultPresenter.fromResult(ToolResult.success(long));
      expect(view.truncated, isTrue);
      expect(view.totalChars, long.length);
      // 截断后的前缀严格等于阈值长度（尾注另算，不能拿总长比较）
      expect(view.displayed, startsWith('z' * ToolResultPresenter.maxEventChars));
      expect(view.displayed, endsWith('\n...(输出已截断)'));
    });

    test('恰好等于阈值时不截断（边界）', () {
      final exact = 'z' * ToolResultPresenter.maxEventChars;
      final view = ToolResultPresenter.fromResult(ToolResult.success(exact));
      expect(view.truncated, isFalse);
      expect(view.displayed, exact);
    });

    test('异常路径永不截断，长度按异常文本计', () {
      final err = StateError('x' * 9000);
      final view = ToolResultPresenter.fromError(err);
      expect(view.truncated, isFalse);
      expect(view.displayed, err.toString());
      expect(view.totalChars, err.toString().length);
    });
  });

  group('ToolGate', () {
    final writeTool = _ProbeTool('file_write', ToolKind.write);
    final readTool = _ProbeTool('file_read', ToolKind.read);

    test('工具不存在时拦截并回传可用清单', () {
      final block = ToolGate.evaluate(
        toolName: 'ghost',
        tool: null,
        permissionMode: AgentPermissionMode.ask,
        allToolNames: () => ['file_read', 'file_write'],
        visibleToolNames: () => ['file_read', 'file_write'],
        isLocalSession: true,
      );
      expect(block, isNotNull);
      expect(block!.reason, ToolGateReason.unknownTool);
      expect(block.isWarning, isTrue);
      expect(block.logMessage, '未知工具: ghost');
      expect(block.observation, contains('工具 ghost 不存在'));
      expect(block.observation, contains('file_read, file_write'));
      expect(block.notice.text, isNotNull);
    });

    test('只读档拦截写类工具', () {
      final block = ToolGate.evaluate(
        toolName: 'file_write',
        tool: writeTool,
        permissionMode: AgentPermissionMode.readOnly,
        allToolNames: () => ['file_write'],
        visibleToolNames: () => ['file_write'],
        isLocalSession: true,
      );
      expect(block, isNotNull);
      expect(block!.reason, ToolGateReason.readOnlyBlocked);
      expect(block.isWarning, isFalse);
      expect(block.observation, ToolGate.readOnlyObservation);
    });

    test('只读档放行只读工具', () {
      final block = ToolGate.evaluate(
        toolName: 'file_read',
        tool: readTool,
        permissionMode: AgentPermissionMode.readOnly,
        allToolNames: () => ['file_read'],
        visibleToolNames: () => ['file_read'],
        isLocalSession: true,
      );
      expect(block, isNull);
    });

    test('作用域外拦截并回传当前会话可用工具', () {
      final block = ToolGate.evaluate(
        toolName: 'project_analyze',
        tool: writeTool,
        permissionMode: AgentPermissionMode.auto,
        allToolNames: () => ['project_analyze', 'file_read'],
        visibleToolNames: () => ['file_read'],
        isLocalSession: false,
      );
      expect(block, isNotNull);
      expect(block!.reason, ToolGateReason.outOfScope);
      expect(block.isWarning, isTrue);
      expect(block.logMessage, contains('local=false'));
      expect(block.observation, contains('在当前会话不可用'));
      expect(block.observation, contains('file_read'));
    });

    test('三道门禁全部通过时返回 null', () {
      final block = ToolGate.evaluate(
        toolName: 'file_write',
        tool: writeTool,
        permissionMode: AgentPermissionMode.ask,
        allToolNames: () => ['file_write'],
        visibleToolNames: () => ['file_write'],
        isLocalSession: true,
      );
      expect(block, isNull);
    });

    test('放行路径不构建全量工具清单（惰性 getter）', () {
      var allCalls = 0;
      ToolGate.evaluate(
        toolName: 'file_write',
        tool: writeTool,
        permissionMode: AgentPermissionMode.ask,
        allToolNames: () {
          allCalls++;
          return ['file_write'];
        },
        visibleToolNames: () => ['file_write'],
        isLocalSession: true,
      );
      expect(allCalls, 0);
    });

    test('未知工具路径不检查作用域', () {
      var visibleCalls = 0;
      ToolGate.evaluate(
        toolName: 'ghost',
        tool: null,
        permissionMode: AgentPermissionMode.ask,
        allToolNames: () => ['file_read'],
        visibleToolNames: () {
          visibleCalls++;
          return ['file_read'];
        },
        isLocalSession: true,
      );
      expect(visibleCalls, 0);
    });
  });

  group('ToolConfirmation', () {
    test('拒绝与超时的原因文案不同', () {
      expect(ToolConfirmation.reason(true), contains('确认超时'));
      expect(ToolConfirmation.reason(false), '用户拒绝执行该操作');
    });

    test('超时提示引导可以重申一次', () {
      expect(ToolConfirmation.observation(true), contains('暂时离开'));
      expect(ToolConfirmation.observation(true), contains('重申一次'));
    });

    test('明确拒绝提示改用 ask / finish', () {
      final text = ToolConfirmation.observation(false);
      expect(text, contains('用户拒绝执行该操作'));
      expect(text, contains('ask'));
      expect(text, contains('finish'));
    });

    test('两类提示都带前缀图标', () {
      expect(ToolConfirmation.notice(true).text, startsWith('⏱'));
      expect(ToolConfirmation.notice(false).text, startsWith('❌'));
    });
  });
}

/// 只用于门禁判定的最小工具实现（kind 决定只读/写）
class _ProbeTool extends AgentTool {
  _ProbeTool(this.name, this.kind);

  @override
  final String name;

  @override
  final ToolKind kind;

  @override
  String get description => '测试用工具';

  @override
  String get paramSpec => '';

  @override
  Future<ToolResult> execute({
    required CommandExecutor executor,
    required ToolArgs args,
    void Function(String message)? onProgress,
  }) async =>
      ToolResult.success('ok');
}
