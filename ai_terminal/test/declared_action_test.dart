import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/agent_model.dart';
import 'package:ai_terminal/services/agent_engine.dart';

/// N1 动作/工具行取值回归（混用冒号 + 尾随注解）
///
/// 旧实现 `contains('：')` 优先全角：「动作: finish（原因：磁盘满）」会切到
/// 括号内的全角冒号，值变成 `finish（原因` → 动作识别失败，R10 丢整轮命令；
/// 动作值也不容忍尾随注解。修复后统一 _protocolValue：先出现的冒号 +
/// 首个空白/括号前的词，五处取值共用。
void main() {
  group('_declaredTextAction / _declaresExecuteAction / scope 取值', () {
    test('纯 ASCII 冒号 + 注解（空格分隔）', () {
      final r = AgentEngine.declaredActionForTest(
          '思考: 检查\n动作: execute（执行）\n命令: ls -la');
      expect(r.declared, ActionType.execute);
      expect(r.executes, isTrue);
      expect(r.scopeText, isNotNull);
      expect(r.scopeText, contains('命令: ls -la'));
    });

    test('混用冒号：ASCII 先出现，全角在括号内（修复前识别失败）', () {
      final r = AgentEngine.declaredActionForTest('动作: finish（原因：磁盘已清理）');
      expect(r.declared, ActionType.finish,
          reason: '按全角优先会切到括号里的冒号，值成 finish（原因 → 未识别');
      expect(r.executes, isFalse);
      expect(r.scopeText, isNull, reason: 'finish 轮没有可执行 scope');
    });

    test('纯全角冒号仍正常', () {
      final r = AgentEngine.declaredActionForTest('动作：ask\n选项: 是|否');
      expect(r.declared, ActionType.ask);
    });

    test('无括号注解无空格（finish（原因:xx）紧邻括号）', () {
      final r = AgentEngine.declaredActionForTest('动作: finish（任务已完成）');
      expect(r.declared, ActionType.finish);
    });

    test('tool 动作识别', () {
      final r = AgentEngine.declaredActionForTest('动作: tool');
      expect(r.declared, ActionType.tool);
    });

    test('未知动作值 → null（R10 保持不执行）', () {
      final r = AgentEngine.declaredActionForTest('动作: 直接执行');
      expect(r.declared, isNull);
      expect(r.executes, isFalse);
      expect(r.scopeText, isNull);
    });

    test('多条动作行：首条定型', () {
      final r = AgentEngine.declaredActionForTest(
          '动作: finish（说明）\n动作: execute\n命令: rm -rf /tmp/x');
      expect(r.declared, ActionType.finish);
      expect(r.executes, isFalse);
    });
  });

  group('parseToolAction 取值（工具:/参数: 行）', () {
    test('工具名带括号注解', () {
      final (name, _) =
          AgentEngine.parseToolAction(['工具: ssh_exec（远程执行）', '参数:'], 0);
      expect(name, 'ssh_exec');
    });

    test('工具名全角冒号 + 注解', () {
      final (name, _) =
          AgentEngine.parseToolAction(['工具：local_file_read 读取本地文件', '参数:'], 0);
      expect(name, 'local_file_read');
    });

    test('参数: 行保留冒号后完整内容（含其后的冒号）', () {
      // 参数值自身含冒号（路径/URL），不能被"取值"逻辑截断
      final (_, args) = AgentEngine.parseToolAction([
        '工具: file_read',
        '参数:',
        '  path: /etc/hosts',
      ], 0);
      expect(args, isNotNull);
      expect(args!['path'], '/etc/hosts');
    });

    // 回归（2026-11-20 真机）：文本协议下模型会吐孤立 XML 闭合标签，
    // 未配对时上面的成对正则匹配不到，脏标签会漏进参数值被原样使用。
    test('参数值尾部的 </parameter> 残留被剥离', () {
      final (_, args) = AgentEngine.parseToolAction([
        '工具: local_file_delete',
        '参数:',
        r'  path: C:\Windows\Temp\a.tmp</parameter>',
      ], 0);
      expect(args, isNotNull);
      expect(args!['path'], isNot(contains('parameter>')));
      expect(args['path'], contains('a.tmp'));
    });

    test('参数值为纯残留时不产生脏参数', () {
      final (_, args) = AgentEngine.parseToolAction([
        '工具: local_file_delete',
        '参数:',
        '  </parameter>',
      ], 0);
      // 剥离后无有效键值 → 参数为空，下游走"缺参数"提示而不是执行脏值
      if (args != null) {
        expect(args.toString(), isNot(contains('parameter>')));
      }
    });
  });
}
