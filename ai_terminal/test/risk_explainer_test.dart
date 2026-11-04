import 'package:flutter_test/flutter_test.dart';

import 'package:ai_terminal/services/agent_tool.dart';
import 'package:ai_terminal/utils/risk_explainer.dart';

void main() {
  group('RiskExplainer', () {
    test('restart service explains interruption and no auto rollback', () {
      final explanation = RiskExplainer.explain('sudo systemctl restart nginx');
      expect(explanation.impact, contains('重启服务'));
      expect(explanation.reason, isNotNull);
      expect(explanation.canRollback, isFalse);
      expect(explanation.rollbackCommand, isNull);
    });

    test('install explains dependency impact and provides rollback', () {
      final explanation = RiskExplainer.explain('sudo apt install nginx');
      expect(explanation.impact, contains('安装'));
      expect(explanation.canRollback, isTrue);
      expect(explanation.rollbackCommand, contains('remove nginx'));
    });

    test('permission change explains access impact without auto rollback', () {
      final explanation = RiskExplainer.explain('sudo chmod 777 /etc/nginx');
      expect(explanation.impact, contains('权限'));
      expect(explanation.canRollback, isFalse);
    });
  });

  group('RiskExplainer.explainTool', () {
    test('本机文件工具说本机，不说服务器', () {
      // 回归：工具展示串曾走 explain()，落到 other 分支写"修改服务器状态"，
      // 而 local_* 改的是跑 App 的这台机器——用户在错误前提下点批准。
      for (final name in [
        'local_file_delete',
        'local_file_write',
        'local_file_patch',
        'local_file_move',
      ]) {
        final impact = RiskExplainer.explainTool(name).impact;
        expect(impact, contains('本机'), reason: '$name 改的是本机');
        expect(impact, isNot(contains('服务器')));
      }
    });

    test('改远程的工具点名远程，不冒充本机操作', () {
      bool mentionsRemote(String s) =>
          s.contains('服务器') || s.contains('远程') || s.contains('远端') || s.contains('主机');
      for (final name in [
        'file_write',
        'file_patch',
        'sftp_upload',
        'upload_to',
        'broadcast_upload',
        'exec_on',
        'exec_batch',
      ]) {
        expect(mentionsRemote(RiskExplainer.explainTool(name).impact), isTrue,
            reason: '$name 动的是别的机器，文案必须点名');
      }
    });

    test('只读工具声明不改动状态', () {
      for (final name in [
        'local_file_read',
        'local_dir_list',
        'local_file_search',
        'project_analyze',
      ]) {
        expect(RiskExplainer.explainTool(name).impact, contains('只读'));
      }
    });

    test('只有真会备份的工具才承诺备份', () {
      // 过度承诺安全性比不承诺更糟：用户会因此省掉自己该做的快照
      for (final name in [
        'local_file_write',
        'local_file_patch',
        'file_write',
        'file_patch',
      ]) {
        expect(RiskExplainer.explainTool(name).impact, contains('自动备份'),
            reason: '$name 覆盖前会备份，文案可以与实现一致');
      }
      for (final name in [
        'sftp_upload',
        'sftp_download',
        'upload_to',
        'broadcast_upload',
        'file_sync',
        'collect_file',
      ]) {
        expect(RiskExplainer.explainTool(name).impact,
            isNot(contains('自动备份')),
            reason: '$name 不备份，文案不能声称会备份');
      }
    });

    test('影响文案与还原文案不互相打脸', () {
      // 曾出现 impact 说"可从台账还原"、下一行却说"无自动回滚，建议先快照"
      final delete = RiskExplainer.explainTool('local_file_delete');
      expect(delete.restoreHint, contains('回收区'));
      expect(RiskExplainer.explainTool('local_file_read').restoreHint,
          contains('只读'));
      // 没有还原路径的工具保持 null，让 UI 给出"无自动回滚"的真实提示
      expect(RiskExplainer.explainTool('sftp_upload').restoreHint, isNull);
      expect(RiskExplainer.explainTool('exec_batch').restoreHint, isNull);
    });

    test('工具影响说明不预测回滚命令', () {
      // 工具的回滚由台账（备份 / 回收区还原）负责，这里编造 shell 命令会误导
      final explanation = RiskExplainer.explainTool('local_file_delete');
      expect(explanation.rollbackCommand, isNull);
      expect(explanation.canRollback, isFalse);
    });

    test('未登记的工具不猜影响哪台机器', () {
      final explanation = RiskExplainer.explainTool('future_mystery_tool');
      expect(explanation.impact, isNot(contains('本机')));
      expect(explanation.impact, isNot(contains('服务器')));
    });

    test('注册表里的每个工具都有具体影响说明，不落到兜底文案', () {
      final registry = AgentToolRegistry()..enableWebTools();
      for (final tool in registry.all) {
        expect(RiskExplainer.explainTool(tool.name).impact,
            isNot('执行工具调用，可能改动当前会话之外的状态'),
            reason: '${tool.name} 新增后必须补影响文案：兜底文案让用户在'
                '不知道影响哪台机器的情况下批准');
      }
    });
  });
}
