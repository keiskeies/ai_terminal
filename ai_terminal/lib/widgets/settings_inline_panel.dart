import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:local_auth/local_auth.dart';

import '../core/constants.dart';
import '../core/app_toast.dart';
import '../core/credentials_store.dart';
import '../core/terminal_keybindings.dart';
import '../core/theme_colors.dart';
import '../core/ui_text.dart';
import '../l10n/app_localizations.dart';
import '../models/ai_endpoint.dart';
import '../models/knowledge_rule.dart';
import '../pages/agent_settings_page.dart' show LocalFileAccessSection;
import '../providers/agent_provider.dart';
import '../providers/app_providers.dart';
import '../providers/knowledge_rule_provider.dart';
import '../services/ai_model_selection_service.dart';
import '../services/change_window_service.dart';
import '../services/daos.dart';
import '../services/mcp_manager.dart';
import '../services/mcp_models.dart';
import '../services/notification_service.dart';
import '../services/web_search_config.dart';
import '../services/web_search_service.dart';
import 'endpoint_editor_form.dart';
import 'inline_form.dart';
import 'keybinding_editor.dart';
import 'mcp_server_editor_form.dart';
import 'rule_editor_form.dart';
import '../core/l10n_holder.dart';

/// 设置页里每一组的就地编辑区。
///
/// **这一块就是完整功能，不是「常用项预览」。** 之前每组只给两三个开关，
/// 想加一台 MCP 服务器、写一条规范、填 Webhook 都得再点「打开完整页面」，
/// 于是设置变成了三层：设置 → 分组 → 二级页面，而且二级页面还是旧配色。
///
/// **现在连编辑表单也在这一块里。** 加端点、改 MCP 服务器、写规范都是把本组
/// 内容整体换成一张 [InlineSheet]，返回即回到列表 —— 设置只有一个载体（右侧
/// 抽屉），不再出现「抽屉里点一下、屏幕中央又弹一个框」的两套入口。
///
/// 同一个组件在抽屉里用，所以布局一律用 Column / Wrap，不写死宽度。
class SettingsInlinePanel extends ConsumerStatefulWidget {
  const SettingsInlinePanel({
    super.key,
    required this.settingsId,
    this.onChanged,
    this.heavy = false,
  });

  /// 与 [kSettingsEntries] 的 id 一致
  final String settingsId;

  /// 值变更后通知外部（标题行的状态读数要跟着变）
  final VoidCallback? onChanged;

  /// 是否渲染「重」区块（本地文件授权的目录列表与回收站统计）。
  /// 整页设置传 true；320 宽的抽屉传 false，否则要滚三屏才到底。
  final bool heavy;

  @override
  ConsumerState<SettingsInlinePanel> createState() =>
      _SettingsInlinePanelState();
}

class _SettingsInlinePanelState extends ConsumerState<SettingsInlinePanel> {
  int _scrollback = 10000;
  bool _sessionLog = false;
  Map<String, List<String>> _keybindings = const {};
  bool _notifyEnabled = false;
  String _notifyTrigger = 'failedOnly';
  bool _webSearchEnabled = false;
  int _webBackendCount = 0;
  List<WebSearchProvider> _webBackends = const [];
  int _webNumResults = 8;
  int _webConcurrency = 6;
  int _webTimeoutMs = 30000;
  String _webProxy = '';
  String? _webProxyError;
  String _webSearxngUrl = '';
  bool _appLockEnabled = false;
  bool _cwEnabled = false;
  int _cwStart = 22;
  int _cwEnd = 6;
  Set<int> _cwDays = {};
  bool _biometricsAvailable = false;
  String _biometricType = '';
  final LocalAuthentication _localAuth = LocalAuthentication();

  // ---- 抽屉内的子视图 ----------------------------------------------------
  // 这些以前各是一个 showDialog。同一个设置页里，一半操作在抽屉里完成、一半
  // 弹到屏幕中央，用户得反复确认自己在哪一层。现在一律「本组内容换一屏」，
  // 顶部一个「返回」回列表，跟抽屉是同一种交互。
  bool _editingEndpoint = false;
  AIEndpoint? _endpointInitial;
  bool _editingMcp = false;
  McpServerConfig? _mcpInitial;
  bool _editingRule = false;
  KnowledgeRule? _ruleInitial;
  bool _showKeybindings = false;
  bool _showPrompt = false;
  bool _showWebPicker = false;
  WebSearchProvider? _webKeyFor;
  WebSearchProvider? _webSearxngFor;
  bool _showWebAdvanced = false;
  bool _showWebTest = false;
  bool _confirmClear = false;

  /// 等待二次确认的条目 id（端点 / MCP / 规范共用），该行就地换成确认条。
  String? _pendingDelete;

  @override
  void initState() {
    super.initState();
    _load();
    _checkBiometrics();
  }

  void _load() {
    try {
      final scrollback = SettingsDao.getCached('terminalScrollback');
      if (scrollback is num) _scrollback = scrollback.toInt();

      final sessionLog = SettingsDao.getCached('sessionLogEnabled');
      if (sessionLog is bool) _sessionLog = sessionLog;

      _keybindings =
          normalizeOverrides(SettingsDao.getCached('terminalKeybindings'));

      final cfg = NotificationService.config;
      _notifyEnabled = cfg.enabled;
      _notifyTrigger = cfg.trigger;

      final web = WebSearchConfig.load();
      _webSearchEnabled = web.enabled;
      _webBackendCount = web.enabledCount;
      _webBackends = web.enabledBackends;
      _webNumResults = web.numResults;
      _webConcurrency = web.concurrency;
      _webTimeoutMs = web.backendTimeoutMs;
      _webProxy = web.proxy;
      _webSearxngUrl = web.searxngInstanceUrl;

      _appLockEnabled =
          SettingsDao.getCached('appLockEnabled', defaultValue: false) == true;

      final cw = ChangeWindowService.config;
      _cwEnabled = cw.enabled;
      _cwStart = cw.startHour;
      _cwEnd = cw.endHour;
      _cwDays = Set<int>.from(cw.allowedWeekdays);
    } catch (_) {}
  }

  Future<void> _checkBiometrics() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final supported = await _localAuth.isDeviceSupported();
      if (!canCheck || !supported) return;
      final types = await _localAuth.getAvailableBiometrics();
      if (!mounted) return;
      setState(() {
        _biometricsAvailable = types.isNotEmpty;
        if (types.contains(BiometricType.face)) {
          _biometricType = 'face';
        } else if (types.contains(BiometricType.fingerprint)) {
          _biometricType = 'fingerprint';
        } else {
          _biometricType = 'generic';
        }
      });
    } catch (_) {}
  }

  void _changed() {
    widget.onChanged?.call();
    if (mounted) setState(() {});
  }

  Future<void> _set(String key, dynamic value) async {
    await ref.read(settingsProvider.notifier).setSetting(key, value);
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    switch (widget.settingsId) {
      case 'terminal':
        return _terminal(tc);
      case 'ai':
        return _ai(tc);
      case 'agent':
        return _agent(tc);
      case 'security':
        return _security(tc);
      case 'mcp':
        return _mcp(tc);
      case 'web_search':
        return _webSearch(tc);
      case 'knowledge_rules':
        return _knowledgeRules(tc);
      case 'notification':
        return _notification(tc);
      default:
        return const SizedBox.shrink();
    }
  }

  // ==================== 终端 ====================

  Widget _terminal(ThemeColors tc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 主题模式 / 终端配色 / 字号已移到顶栏「外观」浮层（边切边看的那类，
        // 一次点击到），这里只留「配一次不再动」的三项。
        _label(tc, UiText.t('回滚缓冲行数', 'Scrollback buffer')),
        const SizedBox(height: 6),
        _chips(
            tc,
            const [
              ('1000', '1 千行', '1k'),
              ('10000', '1 万行', '10k'),
              ('50000', '5 万行', '50k'),
              ('100000', '10 万行', '100k'),
            ],
            '$_scrollback', (v) async {
          _scrollback = int.parse(v);
          await _set('terminalScrollback', _scrollback);
        }),
        const SizedBox(height: 12),
        _toggleRow(
          tc,
          UiText.t('自动会话日志', 'Session logging'),
          _sessionLog,
          (v) async {
            _sessionLog = v;
            await _set('sessionLogEnabled', v);
          },
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(UiText.t('终端快捷键', 'Terminal shortcuts'),
                  style: TextStyle(fontSize: fMicro, color: tc.textMain)),
            ),
            _ChipButton(
              tc: tc,
              label: _showKeybindings
                  ? UiText.t('收起', 'Hide')
                  : UiText.t('编辑', 'Edit'),
              selected: _showKeybindings,
              onTap: () => setState(() => _showKeybindings = !_showKeybindings),
            ),
          ],
        ),
        if (_showKeybindings) ...[
          const SizedBox(height: 8),
          InlineSheet(
            title: UiText.t('终端快捷键', 'Terminal shortcuts'),
            onBack: () => setState(() => _showKeybindings = false),
            children: [
              KeybindingEditorPanel(
                overrides: _keybindings,
                onChanged: (next) async {
                  _keybindings = next;
                  await _set('terminalKeybindings', next);
                },
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ==================== AI 模型 ====================

  Widget _ai(ThemeColors tc) {
    final endpoints = ref.watch(aiEndpointsProvider);
    // 编辑端点 = 本组内容整体换一屏，返回即回到模型列表。
    if (_editingEndpoint) {
      return EndpointEditorForm(
        initial: _endpointInitial,
        onCancel: () => setState(() {
          _editingEndpoint = false;
          _endpointInitial = null;
        }),
        onSave: (next) async {
          await ref.read(aiEndpointsProvider.notifier).saveEndpoint(next);
          if (!mounted) return;
          setState(() {
            _editingEndpoint = false;
            _endpointInitial = null;
          });
          _changed();
        },
      );
    }
    final selected = AIModelSelectionService.selectedModelId ??
        SettingsDao.getCached('aiSelectedModelId') as String? ??
        '';
    final choices = <({String id, String name, String endpoint})>[
      for (final e in endpoints)
        for (final m in e.models) (id: m.id, name: m.name, endpoint: e.name),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(tc, UiText.t('当前使用的模型', 'Active model')),
        const SizedBox(height: 6),
        if (choices.isEmpty)
          _note(
              tc,
              UiText.t('还没有模型。先加一个端点，再往里加模型。',
                  'No model yet — add an endpoint first, then its models.'))
        else
          for (final c in choices)
            _SelectRow(
              tc: tc,
              title: c.name,
              subtitle: c.endpoint,
              selected: c.id == selected,
              onTap: () async {
                await AIModelSelectionService.saveSelectedModel(c.id);
                await _set(AIModelSelectionService.selectedModelKey, c.id);
              },
            ),
        const SizedBox(height: 12),
        _label(tc, UiText.t('端点', 'Endpoints')),
        const SizedBox(height: 6),
        if (endpoints.isEmpty)
          _note(tc, UiText.t('还没有端点。', 'No endpoint yet.'))
        else
          for (final e in endpoints) _endpointRow(tc, e),
        const SizedBox(height: 6),
        _addButton(
          tc,
          UiText.t('添加端点', 'Add endpoint'),
          () => setState(() {
            _endpointInitial = null;
            _editingEndpoint = true;
          }),
        ),
      ],
    );
  }

  Widget _endpointRow(ThemeColors tc, AIEndpoint e) {
    if (_pendingDelete == e.id) {
      return InlineConfirm(
        message: UiText.t('删除「${e.name}」及其 ${e.models.length} 个模型？',
            'Delete "${e.name}" and its ${e.models.length} models?'),
        onCancel: () => setState(() => _pendingDelete = null),
        onConfirm: () async {
          await ref.read(aiEndpointsProvider.notifier).deleteEndpoint(e.id);
          if (!mounted) return;
          setState(() => _pendingDelete = null);
          _changed();
        },
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: fMicro, color: tc.textMain),
                ),
                Text(
                  L10n.str.ut_5eb52c419e(e.models.length, e.baseUrl),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: fMicro, color: tc.textMuted),
                ),
              ],
            ),
          ),
          _iconButton(tc, Icons.edit_outlined, UiText.t('编辑', 'Edit'), () {
            setState(() {
              _endpointInitial = e;
              _editingEndpoint = true;
            });
          }),
          _iconButton(tc, Icons.delete_outline, UiText.t('删除', 'Delete'), () {
            setState(() => _pendingDelete = e.id);
          }, danger: true),
        ],
      ),
    );
  }

  // ==================== Agent ====================

  Widget _agent(ThemeColors tc) {
    final maxSteps = ref.watch(agentProvider.select((s) => s.maxSteps));
    final timeout = ref.watch(agentProvider.select((s) => s.aiTimeoutSeconds));
    final notifier = ref.read(agentProvider.notifier);
    final customPrompt =
        (SettingsDao.getCached('customSystemPrompt') as String?) ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepperRow(
          tc,
          UiText.t('最大执行步数', 'Max steps'),
          maxSteps == 0 ? UiText.t('不限', 'Unlimited') : '$maxSteps',
          onMinus: maxSteps == 0
              ? null
              : () {
                  final next = maxSteps <= 5 ? 0 : maxSteps - 5;
                  notifier.setMaxSteps(next < 5 ? 0 : next);
                  _changed();
                },
          onPlus: () {
            final next = maxSteps == 0 ? 5 : maxSteps + 5;
            notifier.setMaxSteps(next > 100 ? 100 : next);
            _changed();
          },
        ),
        const SizedBox(height: 8),
        _stepperRow(
          tc,
          UiText.t('单步响应超时', 'Response timeout'),
          '${timeout}s',
          onMinus: timeout <= 30
              ? null
              : () {
                  notifier.setAiTimeoutSeconds(timeout - 30);
                  _changed();
                },
          onPlus: timeout >= 600
              ? null
              : () {
                  notifier.setAiTimeoutSeconds(timeout + 30);
                  _changed();
                },
        ),
        const SizedBox(height: 8),
        _stepperRow(
          tc,
          UiText.t('命令超时倍数', 'Command timeout'),
          '${_commandTimeoutMultiplier.toStringAsFixed(1)}x',
          onMinus: _commandTimeoutMultiplier <= 0.5
              ? null
              : () =>
                  _setCommandTimeoutMultiplier(_commandTimeoutMultiplier - 0.5),
          onPlus: _commandTimeoutMultiplier >= 5.0
              ? null
              : () =>
                  _setCommandTimeoutMultiplier(_commandTimeoutMultiplier + 0.5),
        ),
        const SizedBox(height: 8),
        // 确认类提示（[Y/n]、Press ENTER）按保守规则自动应答；默认关。
        // 密码类提示永不自动应答（R7），无默认值的确认仍弹窗问人。
        _toggleRow(
          tc,
          UiText.t('确认提示自动应答', 'Auto-answer confirmations'),
          SettingsDao.getCached('agentAutoAnswerEnabled',
                  defaultValue: false) ==
              true,
          (v) => _set('agentAutoAnswerEnabled', v),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _label(tc, UiText.t('自定义提示词', 'Custom prompt')),
            ),
            Text(
              customPrompt.trim().isEmpty
                  ? UiText.t('未设置', 'Not set')
                  : L10n.str.ut_01f2ee338e(customPrompt.trim().length),
              style: TextStyle(fontSize: fMicro, color: tc.textMuted),
            ),
            const SizedBox(width: 8),
            _iconButton(
                tc, Icons.edit_note_rounded, UiText.t('编辑提示词', 'Edit prompt'),
                () {
              setState(() => _showPrompt = !_showPrompt);
            }),
          ],
        ),
        if (_showPrompt) ...[
          const SizedBox(height: 6),
          _PromptEditor(
            initial: customPrompt,
            onCancel: () => setState(() => _showPrompt = false),
            onSave: (text) async {
              setState(() => _showPrompt = false);
              await _set('customSystemPrompt', text);
            },
          ),
        ],
        if (widget.heavy) ...[
          const SizedBox(height: 14),
          Container(height: 1, color: tc.hairline),
          const SizedBox(height: 12),
          // 本地文件授权本来只在 Agent 设置页里，要改授权的目录得再进一层。
          // 整页设置里直接摊开：目录列表、回收站占用都在这里。
          const LocalFileAccessSection(flat: true),
        ],
      ],
    );
  }

  /// 命令超时倍数（0.5–10，默认 1.0），与 command_heuristics 的读取保持一致。
  double get _commandTimeoutMultiplier {
    final saved = SettingsDao.getCached('commandTimeoutMultiplier');
    return (double.tryParse(saved?.toString() ?? '') ?? 1.0).clamp(0.5, 10.0);
  }

  void _setCommandTimeoutMultiplier(double value) {
    final clamped = double.parse(value.clamp(0.5, 5.0).toStringAsFixed(1));
    _set('commandTimeoutMultiplier', clamped);
    _changed();
  }

  // ==================== 安全 ====================

  Widget _security(ThemeColors tc) {
    final l10n = AppLocalizations.of(context)!;
    final biometricLabel = switch (_biometricType) {
      'face' => UiText.t('面容', 'Face'),
      'fingerprint' => UiText.t('指纹', 'Fingerprint'),
      _ => UiText.t('生物识别', 'biometrics'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    UiText.t('应用锁', 'App lock'),
                    style: TextStyle(fontSize: fMicro, color: tc.textMain),
                  ),
                  Text(
                    _appLockEnabled
                        ? L10n.str.ut_92bbd40515(biometricLabel)
                        : UiText.t('已关闭', 'Off'),
                    style: TextStyle(fontSize: fMicro, color: tc.textMuted),
                  ),
                ],
              ),
            ),
            _MiniSwitch(
              tc: tc,
              value: _appLockEnabled,
              onChanged: _toggleAppLock,
            ),
          ],
        ),
        if (!_biometricsAvailable) ...[
          const SizedBox(height: 4),
          _note(
              tc,
              UiText.t('本机没有可用的生物识别，应用锁无法开启。',
                  'No biometrics on this device — app lock cannot be enabled.')),
        ],
        const SizedBox(height: 10),
        _kv(tc, UiText.t('凭据存储', 'Credential store'),
            UiText.t('系统安全存储 + AES 回落', 'OS secure storage + AES fallback')),
        const SizedBox(height: 6),
        _kv(tc, UiText.t('高危命令', 'Dangerous commands'),
            UiText.t('执行前二次确认', 'Always confirmed before running'),
            color: tc.gold),
        const SizedBox(height: 14),
        Container(height: 1, color: tc.hairline),
        const SizedBox(height: 12),
        // 安全时段：开关与编辑都在本组内即时落盘，没有独立页面和保存按钮。
        Row(
          children: [
            Icon(
                _cwEnabled
                    ? Icons.lock_clock_outlined
                    : Icons.lock_open_outlined,
                size: 14,
                color: _cwEnabled ? tc.gold : tc.textSub),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.changeWindowTitle,
                    style: TextStyle(
                        fontSize: fMicro,
                        color: tc.textMain,
                        fontWeight: FontWeight.w600),
                  ),
                  Text(
                    _cwEnabled
                        ? _cwDescribe(l10n)
                        : l10n.changeWindowEnableHint,
                    style: TextStyle(
                        fontSize: fMicro, color: tc.textMuted, height: 1.35),
                  ),
                ],
              ),
            ),
            _MiniSwitch(
              tc: tc,
              value: _cwEnabled,
              onChanged: (v) {
                setState(() => _cwEnabled = v);
                _saveChangeWindow();
              },
            ),
          ],
        ),
        if (_cwEnabled) ...[
          const SizedBox(height: 12),
          _cwHourRow(tc, l10n.changeWindowStartHour, _cwStart,
              (v) => setState(() => _cwStart = v)),
          const SizedBox(height: 8),
          _cwHourRow(tc, l10n.changeWindowEndHour, _cwEnd,
              (v) => setState(() => _cwEnd = v)),
          const SizedBox(height: 6),
          _note(tc, l10n.changeWindowCrossDayHint),
          const SizedBox(height: 12),
          Text(l10n.changeWindowWeekdaysTitle,
              style: TextStyle(fontSize: fMicro, color: tc.textSub)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final day in [1, 2, 3, 4, 5, 6, 7])
                _ChipButton(
                  tc: tc,
                  label: _cwWeekdayName(l10n, day),
                  selected: _cwDays.contains(day),
                  onTap: () {
                    setState(() {
                      if (!_cwDays.remove(day)) _cwDays.add(day);
                    });
                    _saveChangeWindow();
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: tc.goldBg,
              borderRadius: BorderRadius.circular(rSmall),
              border: Border.all(color: tc.gold.withValues(alpha: 0.22)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 13, color: tc.gold),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.changeWindowCurrentWindowInfo(_cwDescribe(l10n)),
                    style: TextStyle(
                        fontSize: fMicro, color: tc.textSub, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        Container(height: 1, color: tc.hairline),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => setState(() => _confirmClear = true),
          behavior: HitTestBehavior.opaque,
          child: Row(
            children: [
              Icon(Icons.delete_forever_outlined, size: 13, color: tc.error),
              const SizedBox(width: 4),
              Text(
                UiText.t('清除本机数据', 'Clear local data'),
                style: TextStyle(fontSize: fMicro, color: tc.error),
              ),
            ],
          ),
        ),
        if (_confirmClear)
          _ClearDataConfirm(
            onCancel: () => setState(() => _confirmClear = false),
            onConfirm: () async {
              setState(() => _confirmClear = false);
              await _performClear();
            },
          ),
      ],
    );
  }

  String _cwFmtHour(int h) => '${h.toString().padLeft(2, '0')}:00';

  String _cwWeekdayName(AppLocalizations l10n, int day) => switch (day) {
        1 => l10n.changeWindowWeekdayMon,
        2 => l10n.changeWindowWeekdayTue,
        3 => l10n.changeWindowWeekdayWed,
        4 => l10n.changeWindowWeekdayThu,
        5 => l10n.changeWindowWeekdayFri,
        6 => l10n.changeWindowWeekdaySat,
        _ => l10n.changeWindowWeekdaySun,
      };

  String _cwDescribe(AppLocalizations l10n) {
    final start = _cwFmtHour(_cwStart);
    final end = _cwFmtHour(_cwEnd);
    if (_cwStart == _cwEnd) return l10n.changeWindowAllDayAllowed;
    final window = _cwStart < _cwEnd
        ? '$start - $end'
        : l10n.changeWindowToNextDay(start, end);
    if (_cwDays.isEmpty) return l10n.changeWindowEveryDay(window);
    final days = _cwDays.toList()..sort();
    return l10n.changeWindowOnlyDays(
        window, days.map((d) => _cwWeekdayName(l10n, d)).join('、'));
  }

  Future<void> _saveChangeWindow() async {
    final tc = ThemeColors.of(context);
    final cfg = ChangeWindowConfig(
      enabled: _cwEnabled,
      startHour: _cwStart,
      endHour: _cwEnd,
      allowedWeekdays: _cwDays.toList()..sort(),
    );
    try {
      await ChangeWindowService.save(cfg);
    } catch (e) {
      if (!mounted) return;
      showTopSnackBar(
        context,
        SnackBar(
          content: Text(AppLocalizations.of(context)!
              .changeWindowSaveFailed(e.toString())),
          backgroundColor: tc.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    _changed();
  }

  Widget _cwHourRow(
      ThemeColors tc, String label, int hour, ValueChanged<int> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: fMicro, color: tc.textSub)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: tc.goldBg,
                borderRadius: BorderRadius.circular(rSmall),
              ),
              child: Text(
                _cwFmtHour(hour),
                style: TextStyle(
                    fontSize: fMicro,
                    color: tc.gold,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: tc.brand,
            inactiveTrackColor: tc.surface,
            thumbColor: tc.brand,
            overlayColor: tc.brandBg,
            valueIndicatorColor: tc.cardElevated,
            valueIndicatorTextStyle:
                TextStyle(fontSize: fMicro, color: tc.textMain),
          ),
          child: Slider(
            value: hour.toDouble(),
            min: 0,
            max: 23,
            divisions: 23,
            label: _cwFmtHour(hour),
            onChanged: (v) => onChanged(v.toInt()),
            onChangeEnd: (_) => _saveChangeWindow(),
          ),
        ),
      ],
    );
  }

  /// 清空主机、模型、会话、快捷命令与全部设置。
  /// 不可逆操作，沿用「输入 DELETE 才放行」。
  Future<void> _performClear() async {
    await HostsDao.clearAll();
    for (final e in AIEndpointsDao.cached) {
      await CredentialsStore.delete(hostId: e.id, type: 'apiKey');
    }
    await AIModelsDao.clearAll();
    await AIEndpointsDao.clearAll();
    await ChatSessionsDao.clearAll();
    await SnippetsDao.clearAll();
    await SettingsDao.clear();
    if (!mounted) return;
    showTopSnackBar(
      context,
      SnackBar(
        content: Text(UiText.t('本机数据已清除', 'Local data cleared')),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _toggleAppLock(bool value) async {
    if (!value) {
      await SettingsDao.set('appLockEnabled', false);
      setState(() => _appLockEnabled = false);
      _changed();
      return;
    }
    // 桌面 / 无生物识别的机器上 local_auth 会直接抛，不能让它冒到 widget 层
    bool ok = false;
    try {
      ok = await _localAuth.authenticate(
        localizedReason: UiText.t('验证身份以开启应用锁', 'Verify to enable app lock'),
        options: const AuthenticationOptions(biometricOnly: false),
      );
    } catch (_) {
      ok = false;
    }
    if (!ok) return;
    await SettingsDao.set('appLockEnabled', true);
    setState(() => _appLockEnabled = true);
    _changed();
  }

  // ==================== MCP ====================

  Widget _mcp(ThemeColors tc) {
    final manager = McpManager.instance;
    if (_editingMcp) {
      return McpServerEditorForm(
        initial: _mcpInitial,
        onCancel: () => setState(() {
          _editingMcp = false;
          _mcpInitial = null;
        }),
        onSave: (cfg) {
          setState(() {
            _editingMcp = false;
            _mcpInitial = null;
          });
          manager.saveServer(cfg).then((_) {
            if (mounted) _changed();
          });
        },
      );
    }
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final configs = manager.configs;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _toggleRow(
              tc,
              UiText.t('启用 MCP', 'Enable MCP'),
              manager.enabled,
              (v) async {
                await manager.setGlobalEnabled(v);
                _changed();
              },
            ),
            const SizedBox(height: 10),
            if (configs.isEmpty)
              _note(tc, UiText.t('还没有服务器。', 'No server yet.'))
            else
              for (final c in configs) _mcpRow(tc, manager, c),
            const SizedBox(height: 6),
            _addButton(tc, UiText.t('添加服务器', 'Add server'), () {
              setState(() {
                _mcpInitial = null;
                _editingMcp = true;
              });
            }),
          ],
        );
      },
    );
  }

  Widget _mcpRow(ThemeColors tc, McpManager manager, McpServerConfig c) {
    if (_pendingDelete == c.id) {
      return InlineConfirm(
        message: UiText.t('删除「${c.name}」？本机保存的 headers / env / token 一并清理。',
            'Delete "${c.name}"? Its headers/env/token on this machine are removed too.'),
        onCancel: () => setState(() => _pendingDelete = null),
        onConfirm: () async {
          await manager.deleteServer(c.id);
          if (!mounted) return;
          setState(() => _pendingDelete = null);
          _changed();
        },
      );
    }
    final runtime = manager.runtimeFor(c.id);
    final connected = runtime?.isConnected == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? tc.ok : tc.textMuted,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: fMicro, color: tc.textMain),
                ),
                Text(
                  connected
                      ? L10n.str.ut_8ecd2c14b5(runtime?.tools.length ?? 0)
                      : UiText.t('未连接', 'Offline'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: fMicro, color: tc.textMuted),
                ),
              ],
            ),
          ),
          _MiniSwitch(
            tc: tc,
            value: c.enabled,
            onChanged: (v) async {
              await manager.setEnabled(c.id, v);
              _changed();
            },
          ),
          _iconButton(tc, Icons.edit_outlined, UiText.t('编辑', 'Edit'), () {
            setState(() {
              _mcpInitial = c;
              _editingMcp = true;
            });
          }),
          _iconButton(tc, Icons.delete_outline, UiText.t('删除', 'Delete'),
              () => setState(() => _pendingDelete = c.id),
              danger: true),
        ],
      ),
    );
  }

  // ==================== 联网搜索 ====================

  Widget _webSearch(ThemeColors tc) {
    final searxngPending =
        WebSearchConfig.load().backendsMissingInstanceUrl().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _toggleRow(
          tc,
          UiText.t('允许 AI 联网搜索', 'Let AI search the web'),
          _webSearchEnabled,
          (v) async {
            final cfg = WebSearchConfig.load().copyWith(enabled: v);
            await cfg.save();
            _load();
            _changed();
          },
        ),
        const SizedBox(height: 10),
        _label(tc, UiText.t('后端', 'Backends')),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final p in _webBackends)
              _WebBackendChip(
                tc: tc,
                provider: p,
                needsKey: p.requiresApiKey,
                pendingUrl: p.missingInstanceUrl(_webSearxngUrl),
                // 缺实例地址的后端，第一动作是点开补地址，不是删掉它
                onTap: () {
                  if (p.requiresInstanceUrl) {
                    _openWebSetup(p);
                  } else {
                    _removeWebBackend(p);
                  }
                },
              ),
            _ChipButton(
              tc: tc,
              label: _showWebPicker
                  ? UiText.t('收起', 'Hide')
                  : '+ ${UiText.t('添加', 'Add')}',
              selected: _showWebPicker,
              onTap: () => setState(() {
                _showWebPicker = !_showWebPicker;
                _webKeyFor = null;
                _webSearxngFor = null;
              }),
            ),
          ],
        ),
        if (_webSearxngFor case final provider?) ...[
          const SizedBox(height: 8),
          _WebSearxngForm(
            provider: provider,
            initialUrl: _webSearxngUrl,
            onCancel: () => setState(() => _webSearxngFor = null),
            onSave: (url, token, tokenCleared) async {
              if (token.isNotEmpty) {
                await WebSearchConfig.saveApiKey(provider, token);
              } else if (tokenCleared) {
                await WebSearchConfig.deleteApiKey(provider);
              }
              await WebSearchConfig.load()
                  .copyWith(searxngInstanceUrl: url)
                  .save();
              if (!mounted) return;
              setState(() => _webSearxngFor = null);
              if (!WebSearchConfig.load().enabledBackends.contains(provider)) {
                await _enableWebBackend(provider);
              }
            },
            onRemove: () => _removeWebBackend(provider),
          ),
        ] else if (_webKeyFor case final provider?) ...[
          const SizedBox(height: 8),
          _WebKeyForm(
            provider: provider,
            onCancel: () => setState(() => _webKeyFor = null),
            onSave: (key) async {
              await WebSearchConfig.saveApiKey(provider, key);
              if (!mounted) return;
              setState(() => _webKeyFor = null);
              await _enableWebBackend(provider);
            },
          ),
        ] else if (_showWebPicker) ...[
          const SizedBox(height: 8),
          _WebBackendPicker(
            onCancel: () => setState(() => _showWebPicker = false),
            onPick: (p) async {
              setState(() => _showWebPicker = false);
              await _pickWebBackend(p);
            },
          ),
        ],
        if (_webSearchEnabled && _webBackendCount == 0) ...[
          const SizedBox(height: 6),
          _note(
              tc,
              UiText.t('一个后端都没启用，等于没开。',
                  'No backend enabled — search will not run.')),
        ] else if (searxngPending && _webSearxngFor == null) ...[
          const SizedBox(height: 6),
          _note(
              tc,
              UiText.t('SearXNG 还差实例地址：点它的胶囊补上，否则每次搜索都会跳过它。',
                  'SearXNG still needs an instance URL — tap its chip, or every search skips it.')),
        ],
        const SizedBox(height: 10),
        _ChipButton(
          tc: tc,
          label: _showWebAdvanced
              ? UiText.t('收起高级', 'Hide advanced')
              : UiText.t('高级 · 代理 / 条数 / 并发 / 超时',
                  'Advanced · proxy / results / concurrency / timeout'),
          selected: _showWebAdvanced,
          onTap: () => setState(() => _showWebAdvanced = !_showWebAdvanced),
        ),
        if (_showWebAdvanced) ...[
          const SizedBox(height: 8),
          _stepperRow(
            tc,
            UiText.t('返回条数', 'Results'),
            '$_webNumResults',
            onMinus: _webNumResults > 1
                ? () => _saveWebNumResults(_webNumResults - 1)
                : null,
            onPlus: _webNumResults < 20
                ? () => _saveWebNumResults(_webNumResults + 1)
                : null,
          ),
          _stepperRow(
            tc,
            UiText.t('并发后端数', 'Concurrent backends'),
            '$_webConcurrency',
            onMinus: _webConcurrency > 1
                ? () => _saveWebConcurrency(_webConcurrency - 1)
                : null,
            onPlus: _webConcurrency < 12
                ? () => _saveWebConcurrency(_webConcurrency + 1)
                : null,
          ),
          _stepperRow(
            tc,
            UiText.t('单后端超时', 'Per-backend timeout'),
            '$_webTimeoutMs ms',
            onMinus: _webTimeoutMs > 3000
                ? () => _saveWebTimeout(_webTimeoutMs - 5000)
                : null,
            onPlus: _webTimeoutMs < 120000
                ? () => _saveWebTimeout(_webTimeoutMs + 5000)
                : null,
          ),
          const SizedBox(height: 6),
          _label(tc, UiText.t('出站代理（可选）', 'Outbound proxy (optional)')),
          const SizedBox(height: 4),
          _WebhookField(
            key: ValueKey('web-proxy-$_webProxy'),
            tc: tc,
            initial: _webProxy,
            hint: 'http://127.0.0.1:7890',
            onSave: _saveWebProxy,
          ),
          if (_webProxyError != null) ...[
            const SizedBox(height: 4),
            Text(_webProxyError!,
                style:
                    TextStyle(fontSize: fMicro, color: tc.error, height: 1.35)),
          ] else ...[
            const SizedBox(height: 4),
            _note(
                tc,
                UiText.t('代理仅支持 http://host:port',
                    'Proxy only supports http://host:port')),
          ],
          const SizedBox(height: 10),
          // 与「高级」同款折叠：收起时只剩一颗按钮，展开才占这半屏。
          // 曾经它常驻且「返回」只清结果——点了没反应，和别处「返回=退上一屏」相悖。
          if (_showWebTest)
            _WebTestPanel(
              enabled: _webSearchEnabled && _webBackendCount > 0,
              onBack: () => setState(() => _showWebTest = false),
            )
          else
            _ChipButton(
              tc: tc,
              label: UiText.t('立即测试', 'Test now'),
              selected: false,
              onTap: () => setState(() => _showWebTest = true),
            ),
        ],
      ],
    );
  }

  /// 打开某个后端的补配置表单；同一时刻只允许存在一张表单
  void _openWebSetup(WebSearchProvider p) {
    setState(() {
      _webSearxngFor = p;
      _webKeyFor = null;
      _showWebPicker = false;
    });
  }

  Future<void> _removeWebBackend(WebSearchProvider p) async {
    final cfg = WebSearchConfig.load();
    final next = cfg.enabledBackends.where((e) => e != p).toList();
    await cfg.copyWith(enabledBackends: next).save();
    if (!mounted) return;
    setState(() => _webSearxngFor = null);
    _load();
    _changed();
  }

  /// 步进器一次一跳：就地写 SettingsDao 并同步内存读数
  Future<void> _patchWeb(
      WebSearchConfig Function(WebSearchConfig cfg) patch) async {
    await patch(WebSearchConfig.load()).save();
    _load();
    _changed();
  }

  Future<void> _saveWebNumResults(int v) =>
      _patchWeb((c) => c.copyWith(numResults: v.clamp(1, 20)));

  Future<void> _saveWebConcurrency(int v) =>
      _patchWeb((c) => c.copyWith(concurrency: v.clamp(1, 12)));

  Future<void> _saveWebTimeout(int v) =>
      _patchWeb((c) => c.copyWith(backendTimeoutMs: v.clamp(3000, 120000)));

  Future<void> _saveWebProxy(String raw) async {
    final normalized = WebSearchConfig.normalizeProxy(raw);
    if (normalized == null) {
      setState(() => _webProxyError = UiText.t(
          '仅支持 http://host:port，不支持 SOCKS5/代理账号密码',
          'Only http://host:port is supported; SOCKS5 and proxy credentials are not'));
      return;
    }
    setState(() => _webProxyError = null);
    await _patchWeb((c) => c.copyWith(proxy: normalized));
  }

  /// 选一个后端：还缺前置配置的，就地换成对应表单；齐了就启用。
  Future<void> _pickWebBackend(WebSearchProvider p) async {
    if (p.missingInstanceUrl(WebSearchConfig.load().searxngInstanceUrl)) {
      setState(() => _webSearxngFor = p);
      return;
    }
    if (p.requiresApiKey) {
      final status = await WebSearchConfig.apiKeyStatus(p);
      if (!status.configured) {
        if (!mounted) return;
        setState(() => _webKeyFor = p);
        return;
      }
    }
    await _enableWebBackend(p);
  }

  Future<void> _enableWebBackend(WebSearchProvider p) async {
    final next = [...WebSearchConfig.load().enabledBackends, p];
    await WebSearchConfig.load()
        .copyWith(enabledBackends: next, enabled: true)
        .save();
    if (!mounted) return;
    _load();
    _changed();
  }

  // ==================== 内部规范 ====================

  Widget _knowledgeRules(ThemeColors tc) {
    final rules = ref.watch(knowledgeRulesProvider);
    final notifier = ref.read(knowledgeRulesProvider.notifier);
    if (_editingRule) {
      final creating = _ruleInitial == null;
      return RuleEditorForm(
        rule: _ruleInitial,
        onCancel: () => setState(() {
          _editingRule = false;
          _ruleInitial = null;
        }),
        onSave: (saved) {
          setState(() {
            _editingRule = false;
            _ruleInitial = null;
          });
          if (creating) {
            notifier.addRule(saved);
          } else {
            notifier.updateRule(saved);
          }
          _changed();
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (rules.isEmpty)
          _note(tc, UiText.t('还没有规则。', 'No rule yet.'))
        else
          for (final r in rules)
            if (_pendingDelete == r.id)
              InlineConfirm(
                message: UiText.t('删除「${r.title}」？AI 不再遵循这条约定。',
                    'Delete "${r.title}"? The AI stops following it.'),
                onCancel: () => setState(() => _pendingDelete = null),
                onConfirm: () async {
                  await notifier.deleteRule(r.id);
                  if (!mounted) return;
                  setState(() => _pendingDelete = null);
                  _changed();
                },
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.subject_rounded, size: 12, color: tc.textMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(fontSize: fMicro, color: tc.textMain),
                          ),
                          Text(
                            _ruleScopeLabel(r),
                            style: TextStyle(
                                fontSize: fMicro, color: tc.textMuted),
                          ),
                        ],
                      ),
                    ),
                    _MiniSwitch(
                      tc: tc,
                      value: r.enabled,
                      onChanged: (v) async {
                        await notifier.toggleEnabled(r, v);
                        _changed();
                      },
                    ),
                    _iconButton(tc, Icons.edit_outlined, UiText.t('编辑', 'Edit'),
                        () {
                      setState(() {
                        _ruleInitial = r;
                        _editingRule = true;
                      });
                    }),
                    _iconButton(
                        tc,
                        Icons.delete_outline,
                        UiText.t('删除', 'Delete'),
                        () => setState(() => _pendingDelete = r.id),
                        danger: true),
                  ],
                ),
              ),
        const SizedBox(height: 6),
        _addButton(tc, UiText.t('添加规则', 'Add rule'), () {
          setState(() {
            _ruleInitial = null;
            _editingRule = true;
          });
        }),
      ],
    );
  }

  String _ruleScopeLabel(KnowledgeRule r) {
    switch (r.scope) {
      case KnowledgeRuleScope.global:
        return UiText.t('所有主机', 'All hosts');
      case KnowledgeRuleScope.group:
        return UiText.t('主机组 · ${r.group ?? ''}', 'Group · ${r.group ?? ''}');
      case KnowledgeRuleScope.host:
        final host = HostsDao.getCachedById(r.hostId ?? '');
        return UiText.t('主机 · ${host?.name ?? r.hostId ?? ''}',
            'Host · ${host?.name ?? r.hostId ?? ''}');
    }
  }

  // ==================== 通知 ====================

  Widget _notification(ThemeColors tc) {
    final cfg = NotificationService.config;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _toggleRow(
          tc,
          UiText.t('任务完成提醒', 'Task notifications'),
          _notifyEnabled,
          (v) async {
            await NotificationService.save(
                NotificationService.config.copyWith(enabled: v));
            _notifyEnabled = v;
            _changed();
          },
        ),
        const SizedBox(height: 10),
        _label(tc, UiText.t('什么时候提醒', 'When to notify')),
        const SizedBox(height: 6),
        _chips(
            tc,
            const [
              ('failedOnly', '仅失败', 'Failures only'),
              ('always', '每次都提醒', 'Every run'),
            ],
            _notifyTrigger, (v) async {
          await NotificationService.save(
              NotificationService.config.copyWith(trigger: v));
          _notifyTrigger = v;
          _changed();
        }),
        const SizedBox(height: 12),
        _label(tc, UiText.t('Webhook 地址', 'Webhook URL')),
        const SizedBox(height: 6),
        _WebhookField(
          tc: tc,
          initial: cfg.webhookUrl,
          onSave: (url) async {
            await NotificationService.save(
                NotificationService.config.copyWith(webhookUrl: url));
            _changed();
          },
        ),
        if (_notifyEnabled && cfg.webhookUrl.trim().isEmpty) ...[
          const SizedBox(height: 4),
          _note(
              tc,
              UiText.t('还没填 Webhook 地址，发不出去。',
                  'No webhook URL — nothing will be sent.')),
        ],
      ],
    );
  }

  // ==================== 零件 ====================

  Widget _label(ThemeColors tc, String text) => Text(
        text,
        style: TextStyle(fontSize: fMicro, color: tc.textSub, height: 1.2),
      );

  Widget _note(ThemeColors tc, String text) => Text(
        text,
        style: TextStyle(fontSize: fMicro, color: tc.textMuted, height: 1.35),
      );

  /// 行内「+ 做什么」按钮，比 FilledButton 矮、不抢视觉。
  Widget _addButton(ThemeColors tc, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add_rounded, size: 13, color: tc.brand),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: fMicro, color: tc.brand)),
        ],
      ),
    );
  }

  Widget _iconButton(
      ThemeColors tc, IconData icon, String tooltip, VoidCallback onTap,
      {bool danger = false}) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
          child: Icon(icon, size: 14, color: danger ? tc.error : tc.textSub),
        ),
      ),
    );
  }

  Widget _chips(
    ThemeColors tc,
    List<(String, String, String)> options,
    String value,
    ValueChanged<String> onSelect,
  ) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (id, zh, en) in options)
          _ChipButton(
            tc: tc,
            label: UiText.t(zh, en),
            selected: id == value,
            onTap: () => onSelect(id),
          ),
      ],
    );
  }

  Widget _kv(ThemeColors tc, String label, String value, {Color? color}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: fMicro, color: tc.textSub, height: 1.3)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
                fontSize: fMicro, color: color ?? tc.textMain, height: 1.3),
          ),
        ),
      ],
    );
  }

  Widget _stepperRow(
    ThemeColors tc,
    String label,
    String value, {
    VoidCallback? onMinus,
    VoidCallback? onPlus,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: TextStyle(fontSize: fMicro, color: tc.textSub)),
        ),
        _StepButton(tc: tc, icon: Icons.remove, onTap: onMinus),
        SizedBox(
          width: 62,
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: fMicro, color: tc.textMain),
          ),
        ),
        _StepButton(tc: tc, icon: Icons.add, onTap: onPlus),
      ],
    );
  }

  Widget _toggleRow(
    ThemeColors tc,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: TextStyle(fontSize: fMicro, color: tc.textMain)),
        ),
        _MiniSwitch(tc: tc, value: value, onChanged: onChanged),
      ],
    );
  }
}

/// Webhook 输入框：自己管 controller，避免父级 setState 重建时丢焦点。
class _WebhookField extends StatefulWidget {
  const _WebhookField({
    super.key,
    required this.tc,
    required this.initial,
    required this.onSave,
    this.hint = 'https://…',
  });

  final ThemeColors tc;
  final String initial;
  final ValueChanged<String> onSave;
  final String hint;

  @override
  State<_WebhookField> createState() => _WebhookFieldState();
}

class _WebhookFieldState extends State<_WebhookField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 32,
            child: TextField(
              controller: _controller,
              style: TextStyle(fontSize: fMicro, color: tc.textMain),
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.hint,
                hintStyle: TextStyle(fontSize: fMicro, color: tc.textMuted),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: tc.border),
                  borderRadius: BorderRadius.circular(rXSmall),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: tc.brand),
                  borderRadius: BorderRadius.circular(rXSmall),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => widget.onSave(_controller.text.trim()),
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(rXSmall),
              border: Border.all(color: tc.border),
            ),
            child: Text(UiText.t('保存', 'Save'),
                style: TextStyle(fontSize: fMicro, color: tc.brand)),
          ),
        ),
      ],
    );
  }
}

/// 已启用的联网后端胶囊：缺 Key 挂金锁，缺实例地址挂橙色警示。
class _WebBackendChip extends StatelessWidget {
  const _WebBackendChip({
    required this.tc,
    required this.provider,
    required this.needsKey,
    required this.pendingUrl,
    required this.onTap,
  });

  final ThemeColors tc;
  final WebSearchProvider provider;

  /// 该后端要 Key（是否已配判不了，Key 在凭据库里）
  final bool needsKey;

  /// 自建实例地址还没填 —— 每次搜索都会跳过它
  final bool pendingUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 地址型后端的点击动作是「打开表单」，画个 × 会让人以为一点就删、不敢点
    final trailing = provider.requiresInstanceUrl
        ? Icons.edit_outlined
        : Icons.close_rounded;
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (pendingUrl)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Icon(Icons.error_outline_rounded, size: 11, color: tc.warn),
          )
        else if (needsKey)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Icon(Icons.key_rounded, size: 11, color: tc.gold),
          ),
        Text(
          provider.displayName,
          style: TextStyle(
            fontSize: fMicro,
            height: 1.1,
            fontWeight: FontWeight.w500,
            color: tc.brand,
          ),
        ),
        const SizedBox(width: 4),
        Icon(trailing, size: 11, color: tc.textMuted),
      ],
    );
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: tc.brandBg,
          borderRadius: BorderRadius.circular(rFull),
          border: Border.all(color: tc.brand),
        ),
        child: label,
      ),
    );
  }
}

/// 抽屉里的小胶囊按钮：选中 = 10% 品牌底 + 品牌描边 + 品牌字。
class _ChipButton extends StatelessWidget {
  const _ChipButton({
    required this.tc,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ThemeColors tc;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        // 这里**不能**用 alignment + 固定 height：Container 一旦带 alignment，
        // 在 Wrap 的宽松约束下会横向撑满，整组 chip 就变成一列全宽按钮
        // （设置抽屉里"主题模式/终端配色"之前就是这样，八个配色竖着占满一屏）。
        // 用垂直 padding 撑高度、宽度交给内层文本自适应，才是设计稿的胶囊。
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? tc.brandBg : Colors.transparent,
          borderRadius: BorderRadius.circular(rFull),
          border: Border.all(color: selected ? tc.brand : tc.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: fMicro,
            height: 1.1,
            fontWeight: selected ? FontWeight.w500 : FontWeight.normal,
            color: selected ? tc.brand : tc.textSub,
          ),
        ),
      ),
    );
  }
}

/// 单选行（模型列表）：选中行左侧一个点 + 品牌字。
class _SelectRow extends StatelessWidget {
  const _SelectRow({
    required this.tc,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final ThemeColors tc;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? tc.brandBg : Colors.transparent,
          borderRadius: BorderRadius.circular(rXSmall),
          border: Border.all(color: selected ? tc.brand : tc.hairline),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              size: 12,
              color: selected ? tc.brand : tc.textMuted,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fMicro,
                  color: selected ? tc.brand : tc.textMain,
                ),
              ),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                style: TextStyle(fontSize: fMicro, color: tc.textMuted),
              ),
          ],
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.tc, required this.icon, this.onTap});

  final ThemeColors tc;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(rXSmall),
          border: Border.all(color: enabled ? tc.border : tc.hairline),
        ),
        child: Icon(icon, size: 12, color: enabled ? tc.textSub : tc.textMuted),
      ),
    );
  }
}

/// 18px 高的小开关：抽屉里放 Material Switch 会撑到 40+ 高。
class _MiniSwitch extends StatelessWidget {
  const _MiniSwitch({
    required this.tc,
    required this.value,
    required this.onChanged,
  });

  final ThemeColors tc;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: animFast,
        width: 32,
        height: 18,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: value ? tc.brand : tc.border,
          borderRadius: BorderRadius.circular(rFull),
        ),
        child: AnimatedAlign(
          duration: animFast,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: value ? tc.bg : tc.cardElevated,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// 自定义提示词：就地展开一块多行输入，保存后收起。
class _PromptEditor extends StatefulWidget {
  const _PromptEditor({
    required this.initial,
    required this.onCancel,
    required this.onSave,
  });

  final String initial;
  final VoidCallback onCancel;
  final ValueChanged<String> onSave;

  @override
  State<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<_PromptEditor> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InlineSheet(
      title: UiText.t('自定义提示词', 'Custom prompt'),
      onBack: widget.onCancel,
      actions: [
        InlineButton(label: UiText.t('取消', 'Cancel'), onTap: widget.onCancel),
        InlineButton(
          label: UiText.t('保存', 'Save'),
          primary: true,
          onTap: () => widget.onSave(_controller.text.trim()),
        ),
      ],
      children: [
        InlineField(
          label: UiText.t('追加到系统提示词之后', 'Appended after the system prompt'),
          controller: _controller,
          maxLines: 8,
          hint:
              UiText.t('写给这台机器的额外约定。', 'Extra instructions for this machine.'),
        ),
      ],
    );
  }
}

/// 清空本机数据：输入 DELETE 才放行的就地确认。
class _ClearDataConfirm extends StatefulWidget {
  const _ClearDataConfirm({required this.onCancel, required this.onConfirm});

  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  State<_ClearDataConfirm> createState() => _ClearDataConfirmState();
}

class _ClearDataConfirmState extends State<_ClearDataConfirm> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final armed = _controller.text.trim() == 'DELETE';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 9, 9, 9),
      decoration: BoxDecoration(
        color: tc.errorBg,
        borderRadius: BorderRadius.circular(rSmall),
        border: Border.all(color: tc.error),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            UiText.t(
              '会删除：主机与密码、AI 模型配置、会话记录、快捷命令、全部设置。不可恢复。',
              'Removes hosts and passwords, AI model config, chats, snippets and all settings. This cannot be undone.',
            ),
            style:
                TextStyle(fontSize: fMicro, color: tc.textMain, height: 1.35),
          ),
          const SizedBox(height: 8),
          InlineField(
            label: UiText.t('输入 DELETE 以确认', 'Type DELETE to confirm'),
            controller: _controller,
            onChanged: (_) => setState(() {}),
            hint: 'DELETE',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Spacer(),
              InlineButton(
                  label: UiText.t('取消', 'Cancel'), onTap: widget.onCancel),
              const SizedBox(width: 6),
              InlineButton(
                label: UiText.t('清除', 'Clear'),
                danger: true,
                onTap: armed ? widget.onConfirm : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 添加搜索后端：候选列在本组里，点一个就选一个。
class _WebBackendPicker extends StatelessWidget {
  const _WebBackendPicker({required this.onCancel, required this.onPick});

  final VoidCallback onCancel;
  final ValueChanged<WebSearchProvider> onPick;

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final cfg = WebSearchConfig.load();
    final candidates = WebSearchProvider.values
        .where((p) => p.isAvailable && !cfg.enabledBackends.contains(p))
        .toList();
    return InlineSheet(
      title: UiText.t('添加搜索后端', 'Add search backend'),
      onBack: onCancel,
      children: [
        if (candidates.isEmpty)
          Text(
            UiText.t('可用的后端都已经加上了。', 'Every available backend is added.'),
            style: TextStyle(fontSize: fMicro, color: tc.textMuted),
          )
        else
          for (final p in candidates)
            GestureDetector(
              onTap: () => onPick(p),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.displayName,
                              style: TextStyle(
                                  fontSize: fSmall, color: tc.textMain)),
                          Text(p.tagline,
                              style: TextStyle(
                                  fontSize: fMicro, color: tc.textMuted)),
                        ],
                      ),
                    ),
                    if (p.requiresApiKey)
                      Icon(Icons.key_rounded, size: 13, color: tc.gold),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

/// 搜索后端的 API Key：就地输入，保存后自动把该后端打开。
class _WebKeyForm extends StatefulWidget {
  const _WebKeyForm({
    required this.provider,
    required this.onCancel,
    required this.onSave,
  });

  final WebSearchProvider provider;
  final VoidCallback onCancel;
  final ValueChanged<String> onSave;

  @override
  State<_WebKeyForm> createState() => _WebKeyFormState();
}

class _WebKeyFormState extends State<_WebKeyForm> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final key = _controller.text.trim();
    return InlineSheet(
      title: L10n.str.ut_fddba05801(widget.provider.displayName),
      onBack: widget.onCancel,
      actions: [
        InlineButton(label: UiText.t('取消', 'Cancel'), onTap: widget.onCancel),
        InlineButton(
          label: UiText.t('保存并启用', 'Save & enable'),
          primary: true,
          onTap: key.isEmpty ? null : () => widget.onSave(key),
        ),
      ],
      children: [
        InlineField(
          label: UiText.t('API Key', 'API Key'),
          controller: _controller,
          obscure: _obscure,
          mono: true,
          onChanged: (_) => setState(() {}),
          hint: widget.provider.envKeyName,
          trailing: IconButton(
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(
              _obscure
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: tc.textSub,
            ),
          ),
        ),
        if (widget.provider.signupUrl.isNotEmpty) ...[
          const SizedBox(height: 6),
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.provider.signupUrl));
              showTopSnackBar(
                context,
                SnackBar(
                  content:
                      Text(L10n.str.ut_8de5894b72(widget.provider.signupUrl)),
                  duration: const Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: Text(
              UiText.t('复制获取 Key 的地址 →', 'Copy the URL to get a key →'),
              style: TextStyle(
                  color: tc.brand,
                  fontSize: fMicro,
                  decoration: TextDecoration.underline),
            ),
          ),
        ],
      ],
    );
  }
}

/// SearXNG 自建实例：地址必填、Token 可选，保存即启用该后端。
///
/// 加了后端却因为没地址被搜索静默跳过，是这块最早的功能性 bug：地址必须
/// 在启用前拿到，不能等用户跑一次搜索才发现。
class _WebSearxngForm extends StatefulWidget {
  const _WebSearxngForm({
    required this.provider,
    required this.initialUrl,
    required this.onCancel,
    required this.onSave,
    required this.onRemove,
  });

  final WebSearchProvider provider;
  final String initialUrl;
  final VoidCallback onCancel;

  /// (地址, Token, 用户是否主动清空过 Token)
  final void Function(String url, String token, bool tokenCleared) onSave;
  final VoidCallback onRemove;

  @override
  State<_WebSearxngForm> createState() => _WebSearxngFormState();
}

class _WebSearxngFormState extends State<_WebSearxngForm> {
  late final TextEditingController _url =
      TextEditingController(text: widget.initialUrl);
  final TextEditingController _token = TextEditingController();
  bool _obscure = true;
  bool _tokenTouched = false;
  bool _confirmRemove = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  /// 掩码框分不清「没改」和「清空」，只在用户真的动过时才写/删 Token
  bool get _tokenCleared => _tokenTouched && _token.text.trim().isEmpty;

  void _save() {
    final url = WebSearchConfig.normalizeInstanceUrl(_url.text);
    if (url == null) {
      setState(() => _error = UiText.t(
          '地址需是 http(s)://host:port，例如 http://127.0.0.1:8888',
          'Enter an address such as http(s)://host:port, e.g. http://127.0.0.1:8888'));
      return;
    }
    setState(() => _error = null);
    widget.onSave(url, _token.text.trim(), _tokenCleared);
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final signupUrl = WebSearchProvider.searxng.signupUrl;
    return InlineSheet(
      title: UiText.t('${widget.provider.displayName} 实例',
          '${widget.provider.displayName} instance'),
      onBack: widget.onCancel,
      error: _error,
      actions: [
        InlineButton(label: UiText.t('取消', 'Cancel'), onTap: widget.onCancel),
        InlineButton(
          label: UiText.t('保存并启用', 'Save & enable'),
          primary: true,
          onTap: _save,
        ),
      ],
      children: [
        InlineField(
          label: UiText.t('SearXNG 实例地址', 'SearXNG instance URL'),
          controller: _url,
          mono: true,
          hint: 'http://127.0.0.1:8888',
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        const SizedBox(height: 6),
        _searxngNote(tc),
        const SizedBox(height: 6),
        InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: signupUrl));
            showTopSnackBar(
              context,
              SnackBar(
                content: Text(L10n.str.ut_8de5894b72(signupUrl)),
                duration: const Duration(seconds: 2),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
          child: Text(
            UiText.t('复制部署文档地址 →', 'Copy the deployment guide URL →'),
            style: TextStyle(
                color: tc.brand,
                fontSize: fMicro,
                decoration: TextDecoration.underline),
          ),
        ),
        const SizedBox(height: 8),
        InlineField(
          label: UiText.t('Token（可选）', 'Token (optional)'),
          controller: _token,
          obscure: _obscure,
          mono: true,
          hint: WebSearchProvider.searxng.envKeyName,
          onChanged: (_) => _tokenTouched = true,
          trailing: IconButton(
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(
              _obscure
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: tc.textSub,
            ),
          ),
        ),
        if (widget.initialUrl.isNotEmpty) ...[
          const SizedBox(height: 8),
          if (_confirmRemove)
            InlineConfirm(
              message: UiText.t('移除 SearXNG 后端？地址与 Token 会保留。',
                  'Remove the SearXNG backend? URL and token stay saved.'),
              onCancel: () => setState(() => _confirmRemove = false),
              onConfirm: () {
                setState(() => _confirmRemove = false);
                widget.onRemove();
              },
            )
          else
            InkWell(
              onTap: () => setState(() => _confirmRemove = true),
              child: Text(
                UiText.t('移除该后端', 'Remove this backend'),
                style: TextStyle(color: tc.warn, fontSize: fMicro),
              ),
            ),
        ],
      ],
    );
  }

  Widget _searxngNote(ThemeColors tc) => Text(
        UiText.t(
          '公共实例（含 searx.be）通常禁用 format=json，只回 HTML，必须自建：'
              'docker run -d -p 8080:8080 searxng/searxng，并在 settings.yml 启用 '
              'search.formats: [html, json]。',
          'Public instances (including searx.be) usually disable format=json and only '
              'return HTML, so host your own: docker run -d -p 8080:8080 searxng/searxng, '
              'then enable search.formats: [html, json] in settings.yml.',
        ),
        style: TextStyle(fontSize: fMicro, color: tc.textMuted, height: 1.35),
      );
}

/// 立即测试：跑一次真实聚合搜索，把每个后端的结果数/耗时/错误摊开。
///
/// 用已保存的配置，不搞旧页那套「草稿 override」——抽屉里其余设置即时生效。
class _WebTestPanel extends StatefulWidget {
  const _WebTestPanel({required this.enabled, required this.onBack});

  final bool enabled;

  /// 收起本面板（连同在途请求一起 dispose 掉），不是只清结果
  final VoidCallback onBack;

  @override
  State<_WebTestPanel> createState() => _WebTestPanelState();
}

class _WebTestPanelState extends State<_WebTestPanel> {
  final TextEditingController _query = TextEditingController(text: 'flutter');
  CancelToken? _cancel;
  int _generation = 0;
  bool _running = false;
  WebSearchResponse? _response;
  String? _error;

  @override
  void dispose() {
    // R2：先作废回写，再取消在途请求，最后释放 controller
    _generation++;
    _cancel?.cancel('panel disposed');
    _cancel = null;
    _query.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final query = _query.text.trim();
    if (query.isEmpty || _running) return;
    final myGeneration = ++_generation;
    _cancel?.cancel('superseded');
    final token = CancelToken();
    _cancel = token;
    setState(() {
      _running = true;
      _response = null;
      _error = null;
    });
    try {
      final response =
          await WebSearchService.instance.search(query, dioCancelToken: token);
      if (!mounted || myGeneration != _generation) return;
      setState(() {
        _running = false;
        _cancel = null;
        _response = response;
      });
    } catch (e) {
      if (!mounted || myGeneration != _generation) return;
      setState(() {
        _running = false;
        _cancel = null;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeColors.of(context);
    final response = _response;
    return InlineSheet(
      title: UiText.t('立即测试', 'Test now'),
      onBack: widget.onBack,
      error: _error ??
          (widget.enabled
              ? null
              : UiText.t('先打开总开关并启用至少一个后端。',
                  'Turn the master switch on and enable at least one backend.')),
      actions: [
        InlineButton(
          label: UiText.t('测试', 'Test'),
          primary: true,
          busy: _running,
          onTap: widget.enabled && !_running ? _run : null,
        ),
      ],
      children: [
        InlineField(label: UiText.t('测试关键词', 'Test query'), controller: _query),
        if (response != null) ...[
          const SizedBox(height: 8),
          Text(
            UiText.t(
              '共 ${response.results.length} 条结果 · '
                  '${response.successCount} 个后端成功 · ${response.failureCount} 个失败',
              '${response.results.length} results · '
                  '${response.successCount} ok · ${response.failureCount} failed',
            ),
            style:
                TextStyle(fontSize: fMicro, color: tc.textMuted, height: 1.35),
          ),
          const SizedBox(height: 4),
          for (final report in response.reports)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    report.ok
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 12,
                    color: report.ok ? tc.ok : tc.error,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '${report.provider.displayName} · ${report.summary}',
                      style: TextStyle(
                          fontSize: fMicro,
                          color: report.ok ? tc.textSub : tc.textMain,
                          height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
