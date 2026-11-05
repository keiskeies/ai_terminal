import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/models/agent_event.dart';
import 'package:ai_terminal/models/operation_report.dart';
import 'package:ai_terminal/utils/conversation_export.dart';

OperationReport _report({
  String goal = '清理 nginx 日志',
  String conclusion = '已清理 3 个日志文件，磁盘释放 2.1G。',
  String? answerBody,
  List<OperationChange> changes = const [],
}) {
  return OperationReport(
    operationId: 'op-1',
    goal: goal,
    elapsedSeconds: 12,
    stepIndex: 3,
    commandSuccessCount: 1,
    commandFailureCount: 0,
    conclusion: conclusion,
    answerBody: answerBody,
    changes: changes,
    finishState: 'success',
  );
}

void main() {
  group('formatAnswerForCopy', () {
    test('带上操作单的目标、结论与命令，不带命令输出', () {
      final events = [
        AgentEvent.report(_report(
          answerBody: '执行了清理并核验了磁盘占用。',
          changes: [
            const OperationChange(
              id: 'c1',
              command: 'rm -f /var/log/nginx/*.gz',
              type: 'delete',
              localRestore: true,
              success: true,
            ),
          ],
        )),
        AgentEvent.thought('我先看了磁盘占用。'),
        AgentEvent.command('df -h', toolName: 'exec_command'),
        AgentEvent.result(
          commandId: 'x',
          success: true,
          output: '/dev/sda1  40G  38G  2.1G  95% /',
        ),
        AgentEvent.finish(summary: '任务完成'),
      ];

      final text = formatAnswerForCopy(events: events);

      expect(text, contains('目标：清理 nginx 日志'));
      expect(text, contains('结论：已清理 3 个日志文件'));
      expect(text, contains('执行了清理并核验了磁盘占用。'));
      expect(text, contains('\$ df -h'));
      expect(text, contains('任务完成'));
      // 输出只供屏上查看，不该混进可粘贴的正文
      expect(text, isNot(contains('/dev/sda1')));
    });

    test('与结论重复的思考不再出现第二遍', () {
      final events = [
        AgentEvent.report(_report()),
        AgentEvent.thought('结论：已清理 3 个日志文件，磁盘释放 2.1G。'),
      ];

      final text = formatAnswerForCopy(events: events);

      expect('已清理 3 个日志文件'.allMatches(text).length, 1);
    });

    test('本机还原类变更不会打印 rollbackCommand=null', () {
      final events = [
        AgentEvent.report(_report(changes: [
          const OperationChange(
            id: 'c1',
            command: 'del C:\\temp\\a.txt',
            type: 'delete',
            localRestore: true,
            success: true,
          ),
        ])),
      ];

      expect(formatAnswerForCopy(events: events), isNot(contains('null')));
    });

    test('工具调用行带工具名前缀，询问行带选项', () {
      final events = [
        AgentEvent.command('/srv/app', toolName: 'local_file_read'),
        AgentEvent.ask('要删除哪个？', ['日志', '缓存']),
      ];

      final text = formatAnswerForCopy(events: events);

      expect(text, contains('› local_file_read /srv/app'));
      expect(text, contains('要删除哪个？'));
      expect(text, contains('- 缓存'));
    });

    test('旧 ReAct 原文不重复协议行', () {
      final events = [
        AgentEvent.text('收到新目标"验证目标行位置"，但缺少具体要验证哪一行。'),
        AgentEvent.ask('要验证哪一行？', ['补充文件名和行号', '取消']),
        AgentEvent.thought('思考: 收到新目标"验证目标行位置"，但缺少具体要验证哪一行。\n'
            '动作: ask\n选项: 补充文件名和行号 | 取消'),
      ];

      final text = formatAnswerForCopy(events: events);

      expect(text, isNot(contains('动作:')));
      expect(text, isNot(contains('选项:')));
      expect('缺少具体要验证哪一行'.allMatches(text).length, 1);
    });

    test('纯文本回答里的命令与选项行原样保留', () {
      final text = formatAnswerForCopy(events: [
        AgentEvent.text('命令：ipconfig /all\n选项：全部 / 仅活动网卡'),
      ]);

      expect(text, contains('命令：ipconfig /all'));
      expect(text, contains('选项：全部 / 仅活动网卡'));
    });

    test('工具调用行不重复工具名', () {
      final text = formatAnswerForCopy(events: [
        AgentEvent.command(
          'local_file_write\n  path: C:\\temp\\a.cmd\n  mode: write',
          toolName: 'local_file_write',
        ),
      ]);

      expect(text, contains('› local_file_write'));
      expect(text, isNot(contains('local_file_write local_file_write')));
      expect(text, contains('path: C:\\temp\\a.cmd'));
    });

    test('整段重述的回答不留空标题残块', () {
      const restated = '## 巡检结论\n\n### 总体判断\n\n### 下一步建议\n'
          '- 排查 strata 与 vmmemWSL 的内存占用细节\n'
          '- 检查 Redis 与 MSIOO 的服务启动失败原因\n'
          '- 梳理 C 盘占用大头目录清单\n'
          '- 把这次检查结果整理成一份巡检报告';
      final text = formatAnswerForCopy(events: [
        AgentEvent.text(restated),
        AgentEvent.text(restated),
      ]);

      expect('## 巡检结论'.allMatches(text).length, 1);
      expect('### 总体判断'.allMatches(text).length, 1);
    });

    test('历史消息没有事件时退回正文，流式中退回增量', () {
      expect(
        formatAnswerForCopy(events: const [], content: '纯文本回答'),
        '纯文本回答',
      );
      expect(
        formatAnswerForCopy(
            events: const [], content: '', streamingContent: '正在生成的回答'),
        '正在生成的回答',
      );
      expect(formatAnswerForCopy(events: const []), isEmpty);
    });
  });

  test('formatOperationReportCopy 与操作单复制内容一致', () {
    final report = _report(answerBody: '正文一/二/三');
    final text = formatOperationReportCopy(report);

    expect(text, startsWith('目标：清理 nginx 日志'));
    expect(text, contains('结论：'));
    expect(text, contains('正文一/二/三'));
  });
}
