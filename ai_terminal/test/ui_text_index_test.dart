import 'package:flutter_test/flutter_test.dart';
import 'package:ai_terminal/core/ui_text.dart';
import 'package:ai_terminal/core/ui_text_index.dart';
import 'package:ai_terminal/l10n/app_localizations_zh.dart';
import 'package:ai_terminal/l10n/app_localizations_de.dart';
import 'package:ai_terminal/l10n/app_localizations_ko.dart';
import 'package:ai_terminal/core/l10n_holder.dart';

void main() {
  setUp(() {});

  test('index size is consistent', () {
    expect(kUiTextIndex.length, kUiTextPairToKey.length);
    for (final entry in kUiTextIndex.entries) {
      final rec = entry.value;
      for (final lang in ['zh', 'en', 'ar', 'de', 'es', 'fr', 'hi', 'it', 'ja', 'ko', 'pt', 'ru', 'th', 'vi']) {
        expect(rec.containsKey(lang), true, reason: '${entry.key} missing $lang');
        expect(rec[lang], isNotEmpty);
      }
    }
  });

  test('static pair lookup returns zh by default', () {
    L10n.setup(AppLocalizationsZh());
    expect(UiText.t('连接验证通过\n', 'Connection verified\n'), '连接验证通过\n');
    expect(UiText.t('命令', 'Command'), '命令');
    expect(UiText.count(3, '台主机', 'hosts'), '3 台主机');
  });

  test('static pair lookup follows locale', () {
    L10n.setup(AppLocalizationsDe());
    // A German locale should not return the zh text for an indexed pair.
    final out = UiText.t('命令', 'Command');
    expect(out, isNot(equals('命令')));
    expect(out, isNotEmpty);
  });

  test('mt translations are distinct per locale', () {
    final rec = kUiTextIndex.values
        .where((r) => r['ja'] != r['zh'] && r['ja'] != r['en'] && r['de'] != r['zh'])
        .first;
    expect(rec['ja'], isNot(rec['zh']));
    expect(rec['de'], isNot(rec['zh']));
    expect(rec['ar'], isNot(rec['zh']));
  });

  test('interpolated getter renders with real newlines', () {
    L10n.setup(AppLocalizationsZh());
    // ut_9c3df15635 summary: '✓ 打包成功\n输出文件: $outputFile\n大小: $sizeStr\n\n可用 sftp_upload 工具...'
    final s = L10n.str.ut_9c3df15635('a.txt', '123B');
    expect(s, contains('\n'));
    expect(s, contains('a.txt'));
    expect(s, contains('123B'));
    expect(s, isNot(contains(r'\n')));
  });

  test('interpolated getter prefix upload progress', () {
    L10n.setup(AppLocalizationsZh());
    final s = L10n.str.ut_dc39c308a2('上传', 10, 20);
    expect(s, contains('上传'));
    expect(s, contains('/20'));
  });

  test('pair key passes the \x1f separator into index lookup', () {
    L10n.setup(AppLocalizationsZh());
    // Ensure the runtime pair-key string (concatenated with \x1f) exists in
    // kUiTextPairToKey for a representative static pair.
    final key = kUiTextPairToKey['命令\x1fCommand'];
    expect(key, isNotNull);
    expect(kUiTextIndex.keys, contains(key));
  });

  test('MCP summary template keys are pure ARB templates, not literal pairs', () {
    // The MCP settings page（新建服务器 flow）summary and capability lines call
    // L10n.str.ut_* ARB template keys directly — the same pattern as
    // terminalOrchestratorConnected. Such keys must NOT get a kUiTextIndex
    // entry, because they have no zh/en Dart literal pair to key on; putting
    // them there breaks the index-size invariant (940 pairs vs 945 entries).
    for (final key in const [
      'ut_babe4e8237', // {connected}/{total} 个服务器
      'ut_95860656bf', // MCP 总开关已关闭 · 已连接 …
      'ut_e12efa5ddb', // {connected}/{total} 个服务器 · Agent 可用 {tools} 个工具
      'ut_3330b55acf', // {value} 个资源
      'ut_cf674ef0f8', // {value} 个提示词
    ]) {
      expect(kUiTextIndex.containsKey(key), false, reason: '$key must not be in the literal-pair index');
      expect(kUiTextPairToKey.containsValue(key), false,
          reason: '$key must not have a literal-pair mapping');
    }
  });

  test('MCP summary getters render counts in zh and ko', () {
    L10n.setup(AppLocalizationsZh());
    final zhSummary =
        L10n.str.ut_e12efa5ddb(2, 3, 8);
    expect(zhSummary, contains('2/3'));
    expect(zhSummary, contains('8'));
    expect(zhSummary, contains('个服务器'));
    final zhCap = '${L10n.str.ut_7c5becde1e(3)} · '
        '${L10n.str.ut_3330b55acf(2)} · ${L10n.str.ut_cf674ef0f8(1)}';
    expect(zhCap, contains('3'));
    expect(zhCap, contains('资源'));

    L10n.setup(AppLocalizationsKo());
    final koSummary = L10n.str.ut_e12efa5ddb(2, 3, 8);
    expect(koSummary, contains('2/3'));
    expect(koSummary, contains('8'));
    // Must NOT contain the English words the old UiText.t fallback produced.
    expect(koSummary.toLowerCase(), isNot(contains('servers')));
    expect(koSummary.toLowerCase(), isNot(contains('tools')));
    expect(L10n.str.ut_95860656bf(0, 3).toLowerCase(), isNot(contains('switch')));
  });
}
