import 'package:go_router/go_router.dart';
import '../pages/terminal_page.dart';
import '../pages/host_edit_page.dart';
import '../pages/host_list_page.dart';
import '../pages/chat_page.dart';
import '../pages/settings_page.dart';
import '../pages/ai_models_page.dart';
import '../pages/snippets_page.dart';
import '../pages/appearance_page.dart';
import '../pages/security_page.dart';
import '../pages/sftp_page.dart';
import '../pages/audit_log_page.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    // 首页 - 终端
    GoRoute(
      path: '/',
      builder: (context, state) => const TerminalPage(),
    ),
    // 服务器管理
    GoRoute(
      path: '/hosts',
      builder: (context, state) => const HostListPage(),
    ),
    // 新建主机
    GoRoute(
      path: '/host/edit',
      builder: (context, state) => const HostEditPage(),
    ),
    // 编辑主机
    GoRoute(
      path: '/host/edit/:id',
      builder: (context, state) {
        final id = state.pathParameters['id'];
        return HostEditPage(hostId: id);
      },
    ),
    // 终端页面（SSH 连接）
    GoRoute(
      path: '/terminal/:hostId',
      builder: (context, state) {
        final hostId = state.pathParameters['hostId']!;
        return TerminalPage(hostId: hostId);
      },
    ),
    // AI 聊天页面
    GoRoute(
      path: '/chat',
      builder: (context, state) {
        final hostId = state.uri.queryParameters['hostId'];
        return ChatPage(hostId: hostId);
      },
    ),
    // 设置页面
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsPage(),
    ),
    // AI 模型配置
    GoRoute(
      path: '/settings/ai',
      builder: (context, state) => const AIModelsPage(),
    ),
    // 外观设置
    GoRoute(
      path: '/settings/appearance',
      builder: (context, state) => const AppearancePage(),
    ),
    // 安全设置
    GoRoute(
      path: '/settings/security',
      builder: (context, state) => const SecurityPage(),
    ),
    // 快捷命令
    GoRoute(
      path: '/snippets',
      builder: (context, state) => const SnippetsPage(),
    ),
    // SFTP 文件浏览器
    GoRoute(
      path: '/sftp/:hostId',
      builder: (context, state) {
        final hostId = state.pathParameters['hostId']!;
        return SftpPage(hostId: hostId);
      },
    ),
    // 审计日志
    GoRoute(
      path: '/audit-log',
      builder: (context, state) {
        final hostId = state.uri.queryParameters['hostId'];
        return AuditLogPage(hostId: hostId);
      },
    ),
  ],
);
