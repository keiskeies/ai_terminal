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

  /// 主机组名的展示文案。
  ///
  /// `'默认'` 是写进 Hive 的持久值，不能改（改了老数据全落进一个新组），也不
  /// 能在这里返回别的值给写回路径用 —— 只用于渲染。比较、筛选、持久化一律比
  /// 较 `'默认'` 原值，和主机编辑页 `host.group == '默认'` 的处理保持一致。
  static String hostGroup(String group) =>
      group == '默认' && L10n.isReady ? L10n.str.hostDefaultGroup : group;
}
