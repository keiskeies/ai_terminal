import 'l10n_holder.dart';
import 'ui_text_index.dart';

/// Runtime localization helper for strings that live outside the
/// widget/ARB layer.
///
/// Design:
/// - Full localization now goes through the 14-locale ARB set. [t] looks up
///   the (zh, en) pair in [kUiTextPairToKey] and returns the current locale's
///   translation from [kUiTextIndex].
/// - When the pair is not indexed (dynamic/interpolated strings) it delegates
///   to [L10n.str] keys where available, or falls back to the zh/en pair.
/// - Locale is taken from [L10n] when initialized; before setup, falls back
///   to zh, matching the old behavior.
class UiText {
  static bool get zh =>
      !L10n.isReady || L10n.str.localeName.toLowerCase().startsWith('zh');

  /// The current locale code (zh/en/ar/de/es/fr/hi/it/ja/ko/pt/ru/th/vi),
  /// or 'zh' when L10n is not ready yet.
  static String get _locale {
    if (!L10n.isReady) return 'zh';
    final name = L10n.str.localeName.toLowerCase();
    if (name == 'zh' || name == 'zh_cn' || name == 'zh_hans') return 'zh';
    if (name == 'en' || name == 'en_us') return 'en';
    for (final l in const [
      'ar', 'de', 'es', 'fr', 'hi', 'it', 'ja', 'ko', 'pt', 'ru', 'th', 'vi',
    ]) {
      if (name.startsWith(l)) return l;
    }
    return 'en';
  }

  static String t(String zhText, String enText) {
    final key = kUiTextPairToKey['$zhText\x1f$enText'];
    if (key != null) {
      final rec = kUiTextIndex[key];
      if (rec != null) {
        final v = rec[_locale];
        if (v != null && v.isNotEmpty) return v;
        // fall back: en, then zh
        final en = rec['en'];
        if (en != null && en.isNotEmpty) return en;
        final zh = rec['zh'];
        if (zh != null && zh.isNotEmpty) return zh;
      }
    }
    return zh ? zhText : enText;
  }

  static String count(int n, String zhUnit, String enUnit) {
    final key = kUiTextPairToKey['$zhUnit\x1f$enUnit'];
    if (key != null) {
      final rec = kUiTextIndex[key];
      if (rec != null) {
        final v = rec[_locale];
        if (v != null && v.isNotEmpty) return '$n $v';
        final en = rec['en'];
        if (en != null && en.isNotEmpty) return '$n $en';
        final zh2 = rec['zh'];
        if (zh2 != null && zh2.isNotEmpty) return '$n $zh2';
      }
    }
    return zh ? '$n $zhUnit' : '$n $enUnit';
  }

  static String hostGroup(String group) =>
      group == '默认' && L10n.isReady ? L10n.str.hostDefaultGroup : group;
}
