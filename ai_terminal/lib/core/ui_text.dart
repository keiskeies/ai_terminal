import 'l10n_holder.dart';

/// zh/en copy for screens that have not been moved into the ARB set yet.
///
/// Matches the [AgentUiText] convention: Chinese and English first, every
/// other locale falls back to English instead of leaking Chinese.
class UiText {
  static bool get zh =>
      !L10n.isReady || L10n.str.localeName.toLowerCase().startsWith('zh');

  static String t(String zhText, String enText) => zh ? zhText : enText;

  static String count(int n, String zhUnit, String enUnit) =>
      zh ? '$n $zhUnit' : '$n $enUnit';
}
