import 'package:flutter/foundation.dart';
import '../core/safety_guard.dart';
import 'daos.dart';

/// 变更窗口（封网期）配置
///
/// 运维场景：在业务高峰期或封网期禁止执行修改性命令，避免误操作导致故障。
/// 仅允许 safe 级（只读）命令执行，warn/blocked/info 级命令一律拒绝。
class ChangeWindowConfig {
  /// 是否启用封网期
  final bool enabled;

  /// 允许变更的开始小时（24h 制，含），例如 22
  final int startHour;

  /// 允许变更的结束小时（24h 制，不含），例如 6 表示 06:00 之前都允许
  final int endHour;

  /// 允许变更的星期（1-7，1=周一，7=周日）。空列表表示不限
  final List<int> allowedWeekdays;

  const ChangeWindowConfig({
    this.enabled = false,
    this.startHour = 22,
    this.endHour = 6,
    this.allowedWeekdays = const [],
  });

  ChangeWindowConfig copyWith({
    bool? enabled,
    int? startHour,
    int? endHour,
    List<int>? allowedWeekdays,
  }) {
    return ChangeWindowConfig(
      enabled: enabled ?? this.enabled,
      startHour: startHour ?? this.startHour,
      endHour: endHour ?? this.endHour,
      allowedWeekdays: allowedWeekdays ?? this.allowedWeekdays,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'startHour': startHour,
        'endHour': endHour,
        'allowedWeekdays': allowedWeekdays,
      };

  static ChangeWindowConfig fromJson(Map<dynamic, dynamic> json) {
    return ChangeWindowConfig(
      enabled: json['enabled'] as bool? ?? false,
      startHour: json['startHour'] as int? ?? 22,
      endHour: json['endHour'] as int? ?? 6,
      allowedWeekdays: (json['allowedWeekdays'] as List?)
              ?.map((e) => int.parse(e.toString()))
              .toList() ??
          const [],
    );
  }
}

/// 变更窗口服务
class ChangeWindowService {
  static const _key = 'changeWindowConfig';

  static ChangeWindowConfig _cache = const ChangeWindowConfig();
  static bool _loaded = false;

  /// 加载配置（启动时调用一次）
  static Future<void> load() async {
    try {
      final raw = SettingsDao.getCached(_key);
      if (raw is Map) {
        _cache = ChangeWindowConfig.fromJson(Map<dynamic, dynamic>.from(raw));
      }
    } catch (e) {
      debugPrint('[ChangeWindow] 加载配置失败: $e');
    }
    _loaded = true;
  }

  /// 获取当前配置
  static ChangeWindowConfig get config {
    if (!_loaded) load();
    return _cache;
  }

  /// 保存配置
  static Future<void> save(ChangeWindowConfig cfg) async {
    _cache = cfg;
    try {
      await SettingsDao.set(_key, cfg.toJson());
    } catch (e) {
      debugPrint('[ChangeWindow] 保存配置失败: $e');
      rethrow;
    }
  }

  /// 判断当前时间是否在允许变更的窗口内
  static bool isWithinWindow(DateTime now) {
    final cfg = config;
    if (!cfg.enabled) return true;

    // 检查星期
    if (cfg.allowedWeekdays.isNotEmpty) {
      // DateTime.weekday: 1=周一, 7=周日，正好和我们的约定一致
      if (!cfg.allowedWeekdays.contains(now.weekday)) {
        return false;
      }
    }

    final hour = now.hour;
    final start = cfg.startHour;
    final end = cfg.endHour;

    if (start == end) {
      // 起止相同：全天允许
      return true;
    }
    if (start < end) {
      // 同一天内窗口：例如 8-18
      return hour >= start && hour < end;
    } else {
      // 跨夜窗口：例如 22-6（22:00 ~ 次日 06:00）
      return hour >= start || hour < end;
    }
  }

  /// 检查命令是否允许在当前窗口执行
  ///
  /// 返回 (allowed, reason)
  /// - allowed=true: 允许执行
  /// - allowed=false: reason 给出拒绝原因
  static (bool, String?) checkCommand(String command) {
    final cfg = config;
    if (!cfg.enabled) return (true, null);

    final level = SafetyGuard.check(command);
    // safe 级命令（只读）始终允许
    if (level == SafetyLevel.safe) return (true, null);

    // 修改性命令需在窗口内
    if (isWithinWindow(DateTime.now())) {
      return (true, null);
    }

    final reason = '当前处于封网期（允许变更窗口: '
        '${_fmtHour(cfg.startHour)}:00 - ${_fmtHour(cfg.endHour)}:00'
        '${cfg.allowedWeekdays.isNotEmpty ? ', 仅 ${_fmtWeekdays(cfg.allowedWeekdays)}' : ''}'
        '），修改性命令被拒绝执行。当前命令安全等级: ${level.name}';
    return (false, reason);
  }

  static String _fmtHour(int h) => h.toString().padLeft(2, '0');

  static String _fmtWeekdays(List<int> days) {
    const names = {1: '周一', 2: '周二', 3: '周三', 4: '周四', 5: '周五', 6: '周六', 7: '周日'};
    return days.map((d) => names[d] ?? '?').join('/');
  }
}
