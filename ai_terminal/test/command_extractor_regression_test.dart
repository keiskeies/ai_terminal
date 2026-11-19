import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/utils/command_extractor.dart';

/// 回归测试：AI 分析型正文里的中文说明文本不得被提取成命令执行。
/// 真实故障样本（用户环境）：
///   "binlog 位置:  /app/docker_volume/mysql/data/  →  appvg-applv  (/app,  57%, 剩 176G)"
///   曾被宽松模式 4 提取成命令 → 终端报 -bash: syntax error near unexpected token '('
void main() {
  group('CommandExtractor 宽松提取不误判分析文本', () {
    test('中文+路径混合说明文本不提取', () {
      const content = '''
思考: 先检查磁盘分布情况。
binlog 位置:  /app/docker_volume/mysql/data/  →  appvg-applv  (/app,  57%, 剩 176G)
磁盘告急的:   /var                            →  sysvg-varlv  (/var, 98%, 剩 145M)
''';
      expect(CommandExtractor.extractCommands(content), isEmpty);
    });

    test('日期+进度条统计文本不被提取', () {
      const content = '''
2026-11-17  ████████████████████████████████████████████  44 个 ≈ 48G   ← 异常
2026-11-09  ███████████████████                           19 个 ≈ 21G   ← 异常
其余 25 天                                                22 个 ≈ 24G   ← 约 1G/天（正常）
''';
      expect(CommandExtractor.extractCommands(content), isEmpty);
    });

    test('纯命令行控制组仍可提取（无协议行、无中文）', () {
      const content = 'cat /app/docker_volume/mysql/data/du.txt\nrm /tmp/old.tar';
      expect(CommandExtractor.extractCommands(content),
          ['cat /app/docker_volume/mysql/data/du.txt']);
    });

    test('代码块内混排中文说明只提取纯命令行', () {
      const content = '''
```bash
binlog 位置:  /app  →  appvg-applv
mv /var/log/old.tar /tmp/
```
''';
      expect(CommandExtractor.extractCommands(content), ['mv /var/log/old.tar /tmp/']);
    });
  });
}
