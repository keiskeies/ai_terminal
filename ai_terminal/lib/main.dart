import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'core/router.dart';
import 'core/db_init.dart';
import 'core/credentials_store.dart';
import 'core/l10n_holder.dart';
import 'l10n/app_localizations.dart';
import 'providers/app_providers.dart';
import 'services/knowledge_service.dart';
import 'services/provider_config_service.dart';
import 'services/change_window_service.dart';
import 'services/notification_service.dart';
import 'services/conversation_service.dart';
import 'services/agent_logger.dart';
import 'services/ssh_connection_pool.dart';
import 'services/crash_reporter.dart';
import 'services/health_check_service.dart';
import 'core/builtin_runbooks.dart';

void main() {
  // 全局异常兜底：捕获所有未处理的异步异常，防止 app 直接崩溃
  // 涉及服务器操作的软件不能因单个异常而崩溃，必须有兜底机制
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // P2-8: CrashReporter 初始化（独立 crash.log，与 agent.log 分离提高信噪比）
    // 必须在其他初始化之前完成，否则后续 init 失败时无法记录到 crash 文件
    await crashReporter.init().catchError((e) {
      debugPrint('[main] CrashReporter 初始化失败: $e');
    });

    // Flutter framework 异常（Widget build/布局溢出等）— 记录日志 + 写入 crash.log
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      try {
        agentLogger.error('FlutterError',
            '框架异常: ${details.exception}\n${details.stack}');
      } catch (_) {}
      // P2-8: 同步写入 crash.log（独立于 agentLogger，保证结构化字段）
      crashReporter.report(
        details.exception,
        details.stack,
        context: 'FlutterError',
      ).catchError((e) {
        debugPrint('[main] crashReporter 写入失败: $e');
      });
    };

    // 先加载 OS 主密钥（不依赖 DB），用于 SQLCipher 全库加密
    await CredentialsStore.loadMasterKey();
    // 初始化加密 SQLite 数据库（用 OS 主密钥作为 PRAGMA key）
    await DbInit.init();
    // 重新加载 DAO 内存缓存，保证 sync 读路径数据一致
    await DbInit.reloadCaches();
    // 初始化内置运维工作流模板（首次安装时写入，已有则跳过）
    await BuiltinRunbooks.initBuiltin();
    // 完成凭据存储初始化（迁移旧凭据数据，依赖 DbInit 已就绪）
    await CredentialsStore.init();
    await ProviderConfigService.init();
    await ChangeWindowService.load();
    await NotificationService.load();

    KnowledgeService().init().catchError((e) {
      debugPrint('[main] 知识库初始化失败: $e');
    });

    // 启动 SSH 连接池空闲清理：每 5 分钟扫描，回收空闲超过 10 分钟的连接
    // 防止用户打开多个 tab 后连接泄漏导致文件描述符耗尽
    SSHConnectionPool.startIdleCleanup(const Duration(minutes: 10));

    // P2-8: 启动健康检查服务（每 5 分钟检查磁盘可写性 + SSH 池活性）
    // 发现异常通过 agentLogger 输出 WARN/ERROR，不阻塞主流程
    healthCheckService.start();

    // 注册应用生命周期监听：在退出时刷盘，避免丢失未持久化的对话/日志
    // AppLifecycleObserver 通过 WidgetsBinding.instance.addObserver 持有引用，不会被 GC
    AppLifecycleObserver();

    runApp(const ProviderScope(child: AISTerminalApp()));
  }, (error, stack) {
    // Zone 级异常兜底：所有未被 try/catch 捕获的异步异常都到这里
    // 记录到 agent 日志而非让 app 崩溃，确保用户操作不中断
    try {
      debugPrint('[ZONE] 未捕获异常: $error\n$stack');
      agentLogger.error('Zone', '未捕获异常: $error\n$stack');
    } catch (_) {
      // agentLogger 本身不可用时，只能 debugPrint
      debugPrint('[ZONE] agentLogger 不可用: $error');
    }
    // P2-8: 同步写入 crash.log（独立于 agentLogger，保证结构化字段）
    crashReporter.report(
      error,
      stack,
      context: 'Zone',
    ).catchError((e) {
      debugPrint('[ZONE] crashReporter 写入失败: $e');
    });
  });
}

/// 监听应用退出，确保延迟写入的数据落盘
class AppLifecycleObserver with WidgetsBindingObserver {
  AppLifecycleObserver() {
    WidgetsBinding.instance.addObserver(this);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    // paused: app 切到后台 — 同步刷盘所有 Hive box（不关闭，可能还会回到前台）
    //   这样即使系统随后杀进程（detached 无时间执行），数据已安全落盘
    // detached: app 即将销毁 — 最后兜底刷盘 + 关闭 Hive
    // resumed: app 回到前台 — 检查 SSH/AI 任务是否还活着
    if (state == AppLifecycleState.resumed) {
      // 后台→前台：iOS/Android 在后台时会挂起网络连接
      // SSH socket 可能已被服务端超时关闭，但 onDone 回调可能未触发（假连接）
      // AI 流式连接可能已死，但看门狗定时器被挂起未触发超时
      // 这里无法直接访问 AgentNotifier（由 Riverpod 管理），
      // 但 Hive 和 agentLogger 已在 paused 时刷盘，数据安全
      // SSH/任务的活性检测由各服务自身的超时和心跳机制兜底
    } else if (state == AppLifecycleState.paused) {
      // 系统可能在毫秒级内挂起进程，每个操作加 3 秒超时确保后续操作能执行
      try {
        await ConversationService().flushAll()
            .timeout(const Duration(seconds: 3));
      } catch (e) {
        debugPrint('[AppLifecycle] flushAll 失败: $e');
      }
      try {
        await agentLogger.flush().timeout(const Duration(seconds: 2));
      } catch (e) {
        debugPrint('[AppLifecycle] agentLogger.flush 失败: $e');
      }
      // SQLite WAL 自动刷盘，无需手动 flush
    } else if (state == AppLifecycleState.detached) {
      try {
        await ConversationService().flushAll()
            .timeout(const Duration(seconds: 3));
      } catch (e) {
        debugPrint('[AppLifecycle] flushAll 失败: $e');
      }
      try {
        await agentLogger.flush().timeout(const Duration(seconds: 2));
      } catch (e) {
        debugPrint('[AppLifecycle] agentLogger.flush 失败: $e');
      }
      // 释放所有 SSH 连接，防止连接泄漏
      try {
        await SSHConnectionPool.dispose().timeout(const Duration(seconds: 2));
      } catch (e) {
        debugPrint('[AppLifecycle] SSHConnectionPool.dispose 失败: $e');
      }
      try {
        await DbInit.close().timeout(const Duration(seconds: 3));
      } catch (e) {
        debugPrint('[AppLifecycle] DbInit.close 失败: $e');
      }
      // P2-8: 停止健康检查定时器（避免 detached 后仍占用资源）
      try {
        await healthCheckService.stop().timeout(const Duration(seconds: 1));
      } catch (e) {
        debugPrint('[AppLifecycle] healthCheckService.stop 失败: $e');
      }
    }
  }
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

    // 读取用户选择的语言：null/'system' 跟随系统，其他为语言代码
    final localeStr = settings['locale'] as String?;
    Locale? locale;
    if (localeStr != null && localeStr != 'system') {
      locale = Locale(localeStr);
    }

    return MaterialApp.router(
      title: 'AI Terminal',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('zh'),
        Locale('en'),
        Locale('ja'),
        Locale('ko'),
        Locale('de'),
        Locale('fr'),
        Locale('ru'),
        Locale('es'),
        Locale('pt'),
        Locale('ar'),
        Locale('it'),
        Locale('hi'),
        Locale('th'),
        Locale('vi'),
      ],
      routerConfig: appRouter,
      builder: (context, child) {
        // 每次路由重建时更新全局 L10n holder，让非 Widget 类也能访问本地化字符串
        // 语言切换后 context 会重建，此处会同步更新
        final l10n = Localizations.of<AppLocalizations>(context, AppLocalizations);
        if (l10n != null) L10n.setup(l10n);
        return child!;
      },
    );
  }
}
