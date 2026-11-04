import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/services/mcp_models.dart';

void main() {
  group('MCP 名称与配置', () {
    test('mcpSlug 清洗非法字符并限制长度', () {
      expect(mcpSlug('My Server!'), 'my_server');
      expect(mcpSlug('  '), 'server');
      expect(mcpSlug('a' * 100, maxLength: 10), 'aaaaaaaaaa');
    });

    test('mcpToolFullName 使用命名空间且不超过 64 字符', () {
      final name = mcpToolFullName('exa', 'web search');
      expect(name, 'mcp__exa__web_search');
      expect(name.length, lessThanOrEqualTo(64));
      expect(
        mcpToolFullName('server' * 10, 'tool' * 20).length,
        lessThanOrEqualTo(64),
      );
    });

    test('配置 JSON 不包含 headers/env/secret', () {
      const config = McpServerConfig(
        id: 's1',
        name: 'Server',
        headers: {'Authorization': 'secret'},
        env: {'TOKEN': 'secret'},
        oauthClientSecret: 'secret',
      );
      final json = config.toJson();
      expect(json.containsKey('headers'), isFalse);
      expect(json.containsKey('env'), isFalse);
      expect(json.containsKey('oauthClientSecret'), isFalse);
      final restored = McpServerConfig.fromJson(json);
      expect(restored.id, 's1');
      expect(restored.headers, isEmpty);
      expect(restored.timeoutMs, 30000);
      expect(restored.toolExposure, McpToolExposure.readOnly);
    });

    test('预设 Exa / Parallel 使用免 Key Streamable HTTP', () {
      final exa = McpServerConfig.presetExa();
      final parallel = McpServerConfig.presetParallel();
      expect(exa.url, 'https://mcp.exa.ai/mcp');
      expect(parallel.url, 'https://search.parallel.ai/mcp');
      expect(exa.transport, McpTransportKind.streamableHttp);
      expect(exa.oauth, isFalse);
      expect(exa.enabled, isTrue);
    });

    test('OAuth token 过期判断', () {
      final expired = McpOAuthTokenData(
        accessToken: 'a',
        expiresAtMs: DateTime.now().millisecondsSinceEpoch - 1000,
      );
      final valid = McpOAuthTokenData(
        accessToken: 'b',
        expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
      );
      expect(expired.isExpired, isTrue);
      expect(valid.isExpired, isFalse);
      expect(McpOAuthTokenData.fromJson(valid.toJson()).accessToken, 'b');
    });
  });
}
