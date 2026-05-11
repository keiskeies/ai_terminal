import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/theme.dart';
import 'core/theme_colors.dart';
import 'core/router.dart';
import 'core/hive_init.dart';
import 'core/constants.dart';
import 'providers/app_providers.dart';
import 'services/knowledge_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 Hive
  await HiveInit.init();

  // 初始化知识库（异步，不阻塞启动；失败则降级为不可用）
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

// ===== 启动页 =====
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        GoRouter.of(context).go('/');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ThemeColors.of(context).bg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.terminal, size: 64, color: cPrimary),
            const SizedBox(height: 16),
            Text(
              'AI Terminal',
              style: TextStyle(
                color: ThemeColors.of(context).textMain,
                fontSize: 24,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'v1.3.0',
              style: TextStyle(color: ThemeColors.of(context).textSub, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
