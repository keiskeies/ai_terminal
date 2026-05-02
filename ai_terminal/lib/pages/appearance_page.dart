import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../core/theme_colors.dart';
import '../core/hive_init.dart';
import '../providers/app_providers.dart';

class AppearancePage extends ConsumerStatefulWidget {
  const AppearancePage({super.key});

  @override
  ConsumerState<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends ConsumerState<AppearancePage> {
  String _themeMode = 'dark';
  double _fontSize = 13;
  String _colorScheme = 'Monokai';

  final _colorSchemes = {
    'Monokai': {
      'background': const Color(0xFF0C0C0C),
      'foreground': const Color(0xFF4ADE80),
    },
    'Dracula': {
      'background': const Color(0xFF282A36),
      'foreground': const Color(0xFFF8F8F2),
    },
    'Solarized Dark': {
      'background': const Color(0xFF002B36),
      'foreground': const Color(0xFF839496),
    },
    'Nord': {
      'background': const Color(0xFF2E3440),
      'foreground': const Color(0xFFD8DEE9),
    },
  };

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    try {
      final themeMode = HiveInit.settingsBox.get('themeMode');
      if (themeMode != null) _themeMode = themeMode as String;

      final fontSize = HiveInit.settingsBox.get('terminalFontSize');
      if (fontSize != null) _fontSize = (fontSize as num).toDouble();

      final colorScheme = HiveInit.settingsBox.get('terminalColorScheme');
      if (colorScheme != null) _colorScheme = colorScheme as String;
    } catch (_) {}
  }

  Future<void> _saveThemeMode(String mode) async {
    setState(() => _themeMode = mode);
    await HiveInit.settingsBox.put('themeMode', mode);
    // 通知 settingsProvider 更新
    ref.read(settingsProvider.notifier).setSetting('themeMode', mode);
  }

  Future<void> _saveFontSize(double size) async {
    setState(() => _fontSize = size);
    await HiveInit.settingsBox.put('terminalFontSize', size);
    ref.read(settingsProvider.notifier).setSetting('terminalFontSize', size);
  }

  Future<void> _saveColorScheme(String scheme) async {
    setState(() => _colorScheme = scheme);
    await HiveInit.settingsBox.put('terminalColorScheme', scheme);
    ref.read(settingsProvider.notifier).setSetting('terminalColorScheme', scheme);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('外观设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(pStandard),
        children: [
          // 主题模式
          Card(
            child: Padding(
              padding: const EdgeInsets.all(pStandard),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('主题模式', style: TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  RadioListTile<String>(
                    title: const Text('深色模式'),
                    value: 'dark',
                    groupValue: _themeMode,
                    onChanged: (v) => _saveThemeMode(v!),
                  ),
                  RadioListTile<String>(
                    title: const Text('浅色模式'),
                    value: 'light',
                    groupValue: _themeMode,
                    onChanged: (v) => _saveThemeMode(v!),
                  ),
                  RadioListTile<String>(
                    title: const Text('跟随系统'),
                    value: 'system',
                    groupValue: _themeMode,
                    onChanged: (v) => _saveThemeMode(v!),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 字体大小
          Card(
            child: Padding(
              padding: const EdgeInsets.all(pStandard),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '终端字体大小: ${_fontSize.toInt()}px',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
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
          ),

          const SizedBox(height: 16),

          // 配色方案
          Card(
            child: Padding(
              padding: const EdgeInsets.all(pStandard),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('终端配色方案', style: TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _colorSchemes.containsKey(_colorScheme) ? _colorScheme : 'Monokai',
                    items: _colorSchemes.keys
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) _saveColorScheme(v);
                    },
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 实时预览
          Card(
            child: Container(
              height: 120,
              decoration: BoxDecoration(
                color: _colorSchemes[_colorScheme]?['background'] ?? ThemeColors.of(context).terminalBg,
                borderRadius: BorderRadius.circular(rCard),
              ),
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                '\$ echo "Hello World"\nHello World\n\$ ls -la\ndrwxr-xr-x  5 user  staff   160 Apr 27 17:45 .\ndrwxr-xr-x  3 user  staff    96 Apr 27 17:45 ..\n\$_ ',
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: _fontSize,
                  color: _colorSchemes[_colorScheme]?['foreground'] ?? const Color(0xFF4ADE80),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
