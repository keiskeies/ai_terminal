import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
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
    } catch (_) {}
  }

  Future<void> _saveThemeMode(String mode) async {
    setState(() => _themeMode = mode);
    await HiveInit.settingsBox.put('themeMode', mode);
    ref.read(settingsProvider.notifier).setSetting('themeMode', mode);
  }

  Future<void> _saveFontSize(double size) async {
    setState(() => _fontSize = size);
    await HiveInit.settingsBox.put('terminalFontSize', size);
    ref.read(settingsProvider.notifier).setSetting('terminalFontSize', size);
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
        ],
      ),
    );
  }
}
