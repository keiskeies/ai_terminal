import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'core/theme_colors.dart';
import 'core/router.dart';
import 'core/hive_init.dart';
import 'core/constants.dart';
import 'providers/app_providers.dart';
import 'services/knowledge_service.dart';
import 'services/provider_config_service.dart';
import 'services/change_window_service.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await HiveInit.init();
  await ProviderConfigService.init();
  ChangeWindowService.load();
  NotificationService.load();

  KnowledgeService().init().catchError((e) {
    debugPrint('[main] 知识库初始化失败: $e');
  });

  runApp(const ProviderScope(child: AISTerminalApp()));
}

class AISTerminalApp extends ConsumerWidget {
  const AISTerminalApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final themeModeStr = settings['themeMode'] as String? ?? 'dark';

    ThemeMode themeMode;
    switch (themeModeStr) {
      case 'light':
        themeMode = ThemeMode.light;
        break;
      case 'system':
        themeMode = ThemeMode.system;
        break;
      default:
        themeMode = ThemeMode.dark;
    }

    return MaterialApp.router(
      title: 'AI Terminal',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      routerConfig: appRouter,
    );
  }
}
