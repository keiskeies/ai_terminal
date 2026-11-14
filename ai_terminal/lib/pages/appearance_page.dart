import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../services/daos.dart';
import '../core/terminal_keybindings.dart';
import '../core/terminal_themes.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_providers.dart';
import '../widgets/keybinding_editor.dart';

class AppearancePage extends ConsumerStatefulWidget {
  const AppearancePage({super.key});

  @override
  ConsumerState<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends ConsumerState<AppearancePage> {
  String _themeMode = 'dark';
  double _fontSize = 13;
  int _scrollback = 10000;
  bool _sessionLog = false;
  String _palette = kDefaultTerminalPalette;
  Map<String, List<String>> _keybindings = const {};

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    try {
      final themeMode = SettingsDao.getCached('themeMode');
      if (themeMode != null) _themeMode = themeMode as String;

      final fontSize = SettingsDao.getCached('terminalFontSize');
      if (fontSize != null) _fontSize = (fontSize as num).toDouble();

      final scrollback = SettingsDao.getCached('terminalScrollback');
      if (scrollback is num) _scrollback = scrollback.toInt();

      final sessionLog = SettingsDao.getCached('sessionLogEnabled');
      if (sessionLog is bool) _sessionLog = sessionLog;

      final palette = SettingsDao.getCached('terminalPalette');
      if (palette is String) _palette = palette;

      _keybindings =
          normalizeOverrides(SettingsDao.getCached('terminalKeybindings'));
    } catch (_) {}
  }

  Future<void> _saveThemeMode(String mode) async {
    setState(() => _themeMode = mode);
    await SettingsDao.set('themeMode', mode);
    ref.read(settingsProvider.notifier).setSetting('themeMode', mode);
  }

  Future<void> _saveFontSize(double size) async {
    setState(() => _fontSize = size);
    await SettingsDao.set('terminalFontSize', size);
    ref.read(settingsProvider.notifier).setSetting('terminalFontSize', size);
  }

  Future<void> _saveScrollback(int lines) async {
    setState(() => _scrollback = lines);
    await SettingsDao.set('terminalScrollback', lines);
    ref.read(settingsProvider.notifier).setSetting('terminalScrollback', lines);
  }

  Future<void> _saveSessionLog(bool enabled) async {
    setState(() => _sessionLog = enabled);
    await SettingsDao.set('sessionLogEnabled', enabled);
    ref.read(settingsProvider.notifier).setSetting('sessionLogEnabled', enabled);
  }

  Future<void> _savePalette(String id) async {
    setState(() => _palette = id);
    await SettingsDao.set('terminalPalette', id);
    ref.read(settingsProvider.notifier).setSetting('terminalPalette', id);
  }

  Future<void> _saveKeybindings(Map<String, List<String>> next) async {
    setState(() => _keybindings = next);
    await SettingsDao.set('terminalKeybindings', next);
    ref
        .read(settingsProvider.notifier)
        .setSetting('terminalKeybindings', next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appearanceTitle),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 720;
              if (!isWide) {
                // 窄屏：单列
                return ListView(
                  padding: const EdgeInsets.all(pStandard),
                  children: [
                    _buildThemeCard(),
                    const SizedBox(height: 16),
                    _buildPaletteCard(),
                    ..._keybindingSection(),
                    const SizedBox(height: 16),
                    _buildFontCard(),
                  ],
                );
              }
              // 宽屏：2列
              const spacing = 16.0;
              final itemWidth = (constraints.maxWidth - pStandard * 2 - spacing) / 2;
              return SingleChildScrollView(
                padding: const EdgeInsets.all(pStandard),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: itemWidth,
                      child: Column(
                        children: [
                          _buildThemeCard(),
                          const SizedBox(height: 16),
                          _buildPaletteCard(),
                          ..._keybindingSection(),
                        ],
                      ),
                    ),
                    const SizedBox(width: spacing),
                    SizedBox(width: itemWidth, child: _buildFontCard()),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 主题模式卡片
  Widget _buildThemeCard() {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(pStandard),
        child: RadioGroup<String>(
          groupValue: _themeMode,
          onChanged: (v) => _saveThemeMode(v!),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.appearanceDisplayMode, style: const TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text(l10n.appearanceDisplayModeDesc, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
              const SizedBox(height: 8),
              RadioListTile<String>(
                title: Text(l10n.darkMode),
                value: 'dark',
              ),
              RadioListTile<String>(
                title: Text(l10n.lightMode),
                value: 'light',
              ),
              RadioListTile<String>(
                title: Text(l10n.followSystem),
                value: 'system',
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 字体大小卡片
  Widget _buildFontCard() {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(pStandard),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.terminalFontSize(_fontSize.toInt()),
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(l10n.appearanceFontSizeDesc, style: TextStyle(color: tc.textSub, fontSize: fSmall)),
            Slider(
              value: _fontSize,
              min: 8,
              max: 24,
              divisions: 16,
              label: '${_fontSize.toInt()}px',
              onChanged: _saveFontSize,
            ),
            const SizedBox(height: 16),
            Text(UiText.t('回滚缓冲行数', 'Scrollback buffer'),
                style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(
                UiText.t('终端可回看的历史行数，对新开的标签页生效',
                    'Lines of history kept in the terminal. Applies to newly opened tabs.'),
                style: TextStyle(color: tc.textSub, fontSize: fSmall)),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: _scrollback,
              items: const [1000, 10000, 50000, 100000]
                  .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                  .toList(),
              onChanged: (v) {
                if (v != null) _saveScrollback(v);
              },
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(UiText.t('自动会话日志', 'Session logging'),
                  style: const TextStyle(fontWeight: FontWeight.w500)),
              subtitle: Text(
                  UiText.t(
                      '把终端输出录制到日志文件（sudo 密码自动脱敏），对新开的标签页生效',
                      'Record terminal output to log files (sudo passwords masked). Applies to newly opened tabs.'),
                  style: TextStyle(color: tc.textSub, fontSize: fSmall)),
              value: _sessionLog,
              onChanged: _saveSessionLog,
            ),
          ],
        ),
      ),
    );
  }

  /// 快捷键卡片：只在真有物理键盘的平台上出现。
  /// 手机/平板上终端快捷键本来就点不到，列出来只会让人以为能改却不能改。
  List<Widget> _keybindingSection() {
    if (Platform.isAndroid || Platform.isIOS) return const [];
    final tc = ThemeColors.of(context);
    return [
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(pStandard),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(UiText.t('终端快捷键', 'Terminal shortcuts'),
                  style: const TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text(
                UiText.t('点一条组合键即可重新录入，「+」加一条备用组合',
                    'Click a combo to re-record it, or use "+" to add an extra one'),
                style: TextStyle(color: tc.textSub, fontSize: fSmall),
              ),
              const SizedBox(height: 12),
              KeybindingEditorPanel(
                overrides: _keybindings,
                onChanged: _saveKeybindings,
              ),
            ],
          ),
        ),
      ),
    ];
  }

  /// 终端配色卡片：预设整套 ANSI 16 色 + 背景/光标，带小色板预览。
  /// 只给预设不给逐色取色 —— 配色要整套平衡，让用户一个个调的结果通常是不能看。
  Widget _buildPaletteCard() {    final tc = ThemeColors.of(context);
    final isZh = UiText.zh;
    final isLight = tc.isLight;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(pStandard),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(UiText.t('终端配色', 'Terminal colors'),
                style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(
                UiText.t('整套 ANSI 16 色与背景、光标的搭配，即时生效',
                    'The full ANSI 16-colour set with matching background and cursor. Applies immediately.'),
                style: TextStyle(color: tc.textSub, fontSize: fSmall)),
            RadioGroup<String>(
              groupValue: _palette,
              onChanged: (v) {
                if (v != null) _savePalette(v);
              },
              child: Column(
                children: [
                  for (final palette in kTerminalPalettes)
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: palette.id,
                      title: Text(palette.label(isZh: isZh),
                          style: const TextStyle(fontSize: fSmall)),
                      // 只有暗色版本的配色在亮色模式下会回落成内置亮色，
                      // 说清楚免得用户以为没生效
                      subtitle: isLight && palette.light == null
                          ? Text(
                              UiText.t('此配色只有暗色版本，亮色模式下用默认配色',
                                  'Dark-only palette; the default is used in light mode'),
                              style:
                                  TextStyle(fontSize: fMicro, color: tc.textMuted))
                          : null,
                      secondary: _buildSwatches(
                          paletteSwatches(palette, isLight: isLight)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 配色预览：8 个基础 ANSI 色的小色块
  Widget _buildSwatches(List<Color> colors) {
    return SizedBox(
      width: 74,
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        children: [
          for (final c in colors)
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}
