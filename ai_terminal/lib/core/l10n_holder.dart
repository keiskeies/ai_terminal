import '../l10n/app_localizations.dart';
import '../l10n/app_localizations_zh.dart';

/// 全局国际化字符串 holder，让非 Widget 类也能访问本地化字符串
/// 在 app 启动时通过 L10n.setup(context) 设置
class L10n {
  static AppLocalizations? _instance;

  /// 全局本地化字符串访问器。未初始化时返回中文兜底实例，保证服务层/测试
  /// 在无 Widget context 的情况下调用也不崩溃（与原始 UiText 中未初始化时
  /// 返回 zh 的语义一致，避免 rewrite 到 L10n.str.xxx() 的调用点在 setup 之前
  /// 断言失败或文案突变）。
  static AppLocalizations get str {
    return _instance ?? L10nFallback.zh;
  }

  static bool get isReady => _instance != null;

  /// 在 MaterialApp build 后调用，传入能获取 AppLocalizations 的 context
  static void setup(AppLocalizations localizations) {
    _instance = localizations;
  }
}

/// 未初始化兜底：默认中文（与旧 UiText 未初始化时走 zh 分支一致）。
class L10nFallback {
  static AppLocalizations get zh => _zh ??= AppLocalizationsZh();
  static AppLocalizations? _zh;
}
