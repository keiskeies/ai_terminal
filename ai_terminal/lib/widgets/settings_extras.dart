import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/app_toast.dart';
import '../core/constants.dart';
import '../core/settings_catalog.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_providers.dart';
import '../services/crash_reporter.dart';
import '../services/daos.dart';
import '../services/health_check_service.dart';
import '../services/update_check_service.dart';
import 'settings_row_card.dart';
import '../core/l10n_holder.dart';

/// 设置页「管理」区的入口行（**只在整页设置用**）。
///
/// 这些不是设置，是独立功能页（主机、快捷命令、工作流、审计……），点进去是
/// 另一套 CRUD，所以用向右箭头。
///
/// 抽屉里不用这个组件：抽屉顶部本来就有「主机管理 / 快捷命令 / 运维工作流 /
/// 审计日志」四个分区，设置里再列一遍同样的入口，就是同一件事的两条路。
class SettingsManageRows extends StatelessWidget {
  const SettingsManageRows({
    super.key,
    required this.onNavigate,
    this.dense = false,
    this.onlyRoutes,
  });

  /// 点一条：跳到对应功能页。
  final void Function(String route) onNavigate;

  /// 抽屉里字号小一档
  final bool dense;

  /// 只列这些路由（抽屉里只列能就地切到对应分区的几条）。
  ///
  /// 抽屉顶部本来就有主机/快捷命令/工作流/审计四个分区，点这些行应该是
  /// **把抽屉切到那个分区**，不是 push 一个新页面出来。
  final Set<String>? onlyRoutes;

  @override
  Widget build(BuildContext context) {
    final rows = settingsShortcuts()
        .where((s) => onlyRoutes == null || onlyRoutes!.contains(s.route))
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final s in rows) ...[
          SettingsRowCard(
            dense: dense,
            title: s.title,
            subtitle: s.subtitle,
            onNavigate: () => onNavigate(s.route),
          ),
          if (s != rows.last) const SizedBox(height: kSettingsRowGap),
        ],
      ],
    );
  }
}

/// 设置「关于」区：语言、版本、诊断。
///
/// 三项都就地展开：语言是一列单选，诊断是一块读数。以前这两项各弹一个
/// AlertDialog，跟抽屉里其他操作不是同一种交互 —— 用户在抽屉里点一下，
/// 视线却要跳到屏幕中央。
class SettingsAboutRows extends ConsumerStatefulWidget {
  const SettingsAboutRows({super.key, this.dense = false});

  final bool dense;

  @override
  ConsumerState<SettingsAboutRows> createState() => _SettingsAboutRowsState();
}

class _SettingsAboutRowsState extends ConsumerState<SettingsAboutRows> {
  /// 当前展开的那一项
  String? _open;

  HealthSnapshot? _snap;
  PackageInfo? _info;
  bool _loadingDiag = false;

  static const _languages = <(String, String)>[
    ('zh', '简体中文'),
    ('en', 'English'),
    ('ja', '日本語'),
    ('ko', '한국어'),
    ('de', 'Deutsch'),
    ('fr', 'Français'),
    ('ru', 'Русский'),
    ('es', 'Español'),
    ('pt', 'Português'),
    ('ar', 'العربية'),
    ('it', 'Italiano'),
    ('hi', 'हिन्दी'),
    ('th', 'ภาษาไทย'),
    ('vi', 'Tiếng Việt'),
  ];

  void _toggle(String id) {
    setState(() {
      _open = _open == id ? null : id;
    });
    if (id == 'diagnostics' && _open == 'diagnostics') _loadDiagnostics();
  }

  Future<void> _loadDiagnostics() async {
    if (_loadingDiag) return;
    setState(() => _loadingDiag = true);
    try {
      final info = await PackageInfo.fromPlatform();
      final snap = await healthCheckService.checkNow();
      if (!mounted) return;
      setState(() {
        _info = info;
        _snap = snap;
        _loadingDiag = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingDiag = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 语言改完要立刻显示新语言名。
    ref.watch(settingsProvider);
    final locale = SettingsDao.getCached('locale', defaultValue: 'system');
    final code = locale is String ? locale : 'system';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRowCard(
          dense: widget.dense,
          title: l10n.settingsLanguage,
          subtitle: _languageName(code, l10n),
          expanded: _open == 'language',
          onToggle: () => _toggle('language'),
          detail: [_languageList(code)],
        ),
        const SizedBox(height: kSettingsRowGap),
        _VersionCard(dense: widget.dense),
        const SizedBox(height: kSettingsRowGap),
        SettingsRowCard(
          dense: widget.dense,
          title: UiText.t('诊断', 'Diagnostics'),
          subtitle: _diagnosticsSubtitle(),
          expanded: _open == 'diagnostics',
          onToggle: () => _toggle('diagnostics'),
          detail: [_diagnosticsBody()],
        ),
      ],
    );
  }

  Widget _languageList(String current) {
    final l10n = AppLocalizations.of(context)!;
    final tc = ThemeColors.of(context);
    final options = <(String, String)>[
      ('system', l10n.languageFollowSystem),
      ..._languages,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (code, name) in options)
          GestureDetector(
            onTap: () async {
              await SettingsDao.set('locale', code);
              ref.read(settingsProvider.notifier).setSetting('locale', code);
              if (mounted) setState(() => _open = null);
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              decoration: BoxDecoration(
                color: code == current ? tc.brandBg : Colors.transparent,
                borderRadius: BorderRadius.circular(rXSmall),
              ),
              child: Row(
                children: [
                  Icon(
                    code == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 12,
                    color: code == current ? tc.brand : tc.textMuted,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: fMicro,
                      color: code == current ? tc.brand : tc.textMain,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _diagnosticsBody() {
    final tc = ThemeColors.of(context);
    final snap = _snap;
    if (_loadingDiag && snap == null) {
      return Text(
        UiText.t('检查中…', 'Checking…'),
        style: TextStyle(fontSize: fMicro, color: tc.textMuted),
      );
    }
    if (snap == null) {
      return Row(
        children: [
          Text(
            UiText.t('没有拿到检查结果。', 'No result.'),
            style: TextStyle(fontSize: fMicro, color: tc.textMuted),
          ),
          const Spacer(),
          GestureDetector(
            onTap: _loadDiagnostics,
            behavior: HitTestBehavior.opaque,
            child: Text(UiText.t('重试', 'Retry'),
                style: TextStyle(fontSize: fMicro, color: tc.brand)),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _diagRow(tc, UiText.t('应用版本', 'App version'),
            _info == null ? '—' : '${_info!.version}+${_info!.buildNumber}'),
        _diagRow(tc, UiText.t('本次会话崩溃', 'Crashes this session'),
            '${crashReporter.sessionCrashCount}'),
        _diagRow(
            tc,
            UiText.t('上次崩溃时间', 'Last crash time'),
            crashReporter.lastCrashTime != null
                ? _formatTime(crashReporter.lastCrashTime!)
                : UiText.t('无', 'None')),
        _diagRow(tc, UiText.t('SSH 池连接', 'SSH pool connections'),
            '${snap.sshTotalConnections} (ref=${snap.sshTotalRefCount})'),
        _diagRow(tc, UiText.t('已死连接', 'Dead connections'),
            '${snap.sshDeadConnections}'),
        _diagRow(tc, UiText.t('磁盘可写', 'Disk writable'),
            snap.diskWritable ? UiText.t('是', 'Yes') : UiText.t('否', 'No')),
        _diagRow(
            tc, UiText.t('检查时间', 'Checked at'), _formatTime(snap.timestamp)),
        const SizedBox(height: 8),
        Row(
          children: [
            GestureDetector(
              onTap: () async {
                final content = await crashReporter.readLog();
                if (!mounted) return;
                if (content.isEmpty) {
                  showTopSnackBar(
                      context,
                      SnackBar(
                        content: Text(UiText.t('崩溃日志为空', 'Crash log is empty')),
                        behavior: SnackBarBehavior.floating,
                      ));
                  return;
                }
                await Clipboard.setData(ClipboardData(text: content));
                if (!mounted) return;
                showTopSnackBar(
                    context,
                    SnackBar(
                      content: Text(L10n.str.ut_1568d540be(content.length)),
                      behavior: SnackBarBehavior.floating,
                    ));
              },
              behavior: HitTestBehavior.opaque,
              child: Text(UiText.t('复制崩溃日志', 'Copy crash log'),
                  style: TextStyle(fontSize: fMicro, color: tc.brand)),
            ),
            const SizedBox(width: 14),
            GestureDetector(
              onTap: () async {
                await crashReporter.clearLog();
                if (!mounted) return;
                showTopSnackBar(
                    context,
                    SnackBar(
                      content: Text(UiText.t('已清除崩溃日志', 'Crash log cleared')),
                      behavior: SnackBarBehavior.floating,
                    ));
              },
              behavior: HitTestBehavior.opaque,
              child: Text(UiText.t('清除', 'Clear'),
                  style: TextStyle(fontSize: fMicro, color: tc.textSub)),
            ),
            const Spacer(),
            GestureDetector(
              onTap: _loadDiagnostics,
              behavior: HitTestBehavior.opaque,
              child: Text(UiText.t('重新检查', 'Re-check'),
                  style: TextStyle(fontSize: fMicro, color: tc.textSub)),
            ),
          ],
        ),
      ],
    );
  }

  static String _languageName(String code, AppLocalizations l10n) {
    if (code == 'system') return l10n.languageFollowSystem;
    for (final (id, name) in _languages) {
      if (id == code) return name;
    }
    return l10n.languageFollowSystem;
  }

  static String _diagnosticsSubtitle() {
    final count = crashReporter.sessionCrashCount;
    if (count > 0) {
      return L10n.str.ut_c14c3f2424(count);
    }
    final lastTime = crashReporter.lastCrashTime;
    if (lastTime != null) {
      return UiText.t(
        '上次崩溃: ${_formatTime(lastTime)}',
        'Last crash: ${_formatTime(lastTime)}',
      );
    }
    return UiText.t('崩溃日志与健康状态', 'Crash log and health');
  }

  static String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  static Widget _diagRow(ThemeColors tc, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(label,
                style: TextStyle(color: tc.textSub, fontSize: fMicro)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(color: tc.textMain, fontSize: fMicro)),
          ),
        ],
      ),
    );
  }
}

/// 版本卡片：显示版本号，点按检查更新（GitHub Releases）。
///
/// 中间态回退过一次：先是有个假的「检查更新」按钮（点了只弹版本号），
/// 后来砍成「点按复制」。现在仓库在 GitHub 上有 CI 自动发布的 Release，
/// 检查更新有了真实数据源，就恢复成检查更新 —— 发现新版时整行变成动作，
/// 再点一下打开浏览器到 Release 页。复制版本信息降级为长按（排障时偶尔用）。
class _VersionCard extends StatefulWidget {
  const _VersionCard({this.dense = false});

  final bool dense;

  @override
  State<_VersionCard> createState() => _VersionCardState();
}

class _VersionCardState extends State<_VersionCard> {
  bool _hovering = false;
  String _version = '';

  /// 检查更新的状态机：idle → checking → upToDate / available / failed。
  _UpdateState _state = _UpdateState.idle;
  UpdateInfo? _latest;
  String _error = '';

  @override
  void initState() {
    super.initState();
    // 副标题只显示版本主体：+构建号是打包元数据，普通用户不关心，
    // 要排查问题时「诊断」区里有完整读数。
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _version = normalizeVersion(info.version));
    }).catchError((_) {});
  }

  Future<void> _check() async {
    if (_state == _UpdateState.checking) return;
    setState(() {
      _state = _UpdateState.checking;
      _error = '';
    });
    try {
      final latest = await UpdateCheckService.instance.fetchLatest();
      if (!mounted) return;
      final newer =
          _version.isEmpty || compareVersions(latest.version, _version) > 0;
      setState(() {
        _latest = latest;
        _state = newer ? _UpdateState.available : _UpdateState.upToDate;
      });
    } on UpdateCheckException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _UpdateState.failed;
        _error = e.message;
      });
    }
  }

  Future<void> _openRelease() async {
    final url = _latest?.url;
    if (url == null) return;
    try {
      if (Platform.isWindows) {
        await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      showTopSnackBar(
        context,
        SnackBar(
          content: Text(UiText.t('打开链接失败，已复制到剪贴板',
              'Failed to open the link; copied to clipboard')),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _onTap() {
    // 发现新版之后，这一行就是「去下载」；其余状态点了都是重新检查。
    if (_state == _UpdateState.available) {
      _openRelease();
    } else {
      _check();
    }
  }

  Future<void> _copyVersion() async {
    await Clipboard.setData(ClipboardData(text: 'AI Terminal $_version'));
    if (!mounted) return;
    showTopSnackBar(
      context,
      SnackBar(
        content: Text(UiText.t('已复制版本信息', 'Version info copied')),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final (String sub, Color subColor, IconData icon) = switch (_state) {
      _ when _version.isEmpty => (
          'AI Terminal · ${UiText.t('读取中…', 'Loading…')}',
          tc.textSub,
          Icons.downloading_rounded,
        ),
      _UpdateState.checking => (
          UiText.t('正在检查更新…', 'Checking for updates…'),
          tc.textSub,
          Icons.downloading_rounded,
        ),
      _UpdateState.available => (
          UiText.t('发现新版本 ${_latest?.version ?? ''}，点击查看',
              'Version ${_latest?.version ?? ''} available — tap to open'),
          tc.brand,
          Icons.system_update_alt_rounded,
        ),
      _UpdateState.upToDate => (
          UiText.t('已是最新版本', 'You are on the latest version'),
          tc.ok,
          Icons.check_circle_outline_rounded,
        ),
      _UpdateState.failed => (
          _error,
          tc.error,
          Icons.wifi_tethering_error_rounded,
        ),
      _UpdateState.idle => (
          'AI Terminal · $_version',
          tc.textSub,
          Icons.system_update_alt_rounded,
        ),
    };
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        onLongPress: _version.isEmpty ? null : _copyVersion,
        child: AnimatedContainer(
          duration: animFast,
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: _hovering ? tc.cardElevated : tc.card,
            borderRadius: BorderRadius.circular(rMedium),
            border: Border.all(color: tc.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      UiText.t('版本', 'Version'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: widget.dense ? fMicro : fBody,
                        fontWeight: FontWeight.w500,
                        color: tc.textMain,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: widget.dense ? fMicro : fSmall,
                          color: subColor),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(icon, size: 14, color: subColor),
            ],
          ),
        ),
      ),
    );
  }
}

enum _UpdateState { idle, checking, upToDate, available, failed }
