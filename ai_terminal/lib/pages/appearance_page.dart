import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../services/daos.dart';
import '../core/theme_colors.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_providers.dart';

class AppearancePage extends ConsumerStatefulWidget {
  const AppearancePage({super.key});

  @override
  ConsumerState<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends ConsumerState<AppearancePage> {
  String _themeMode = 'dark';
  double _fontSize = 13;

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
                    SizedBox(width: itemWidth, child: _buildThemeCard()),
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
          ],
        ),
      ),
    );
  }
}
