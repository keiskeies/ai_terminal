import '../l10n/app_localizations.dart';

/// 全局国际化字符串 holder，让非 Widget 类也能访问本地化字符串
/// 在 app 启动时通过 L10n.setup(context) 设置
class L10n {
  static AppLocalizations? _instance;

  static AppLocalizations get str {
    assert(_instance != null, 'L10n 未初始化，请先调用 L10n.setup()');
    return _instance!;
  }

  static bool get isReady => _instance != null;

  /// 在 MaterialApp build 后调用，传入能获取 AppLocalizations 的 context
  static void setup(AppLocalizations localizations) {
    _instance = localizations;
  }
}
