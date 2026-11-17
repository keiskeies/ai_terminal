/// 从**用户文本**里识别「本任务禁止执行命令」的显式约束。
///
/// 引擎的 finish 幻觉门控要求"至少执行过一次命令/工具"才允许收尾。
/// 但用户明确说"严禁执行任何命令，只根据会话内容回答"时，这条门控
/// 和用户意图对着干：白烧掉重试步数，最后只能靠 ask 脱身。
///
/// 调用方只能喂用户原文（任务目标 / 运行中补充 / ask 选项），
/// 不能喂模型正文 —— 模型自己声称"无需执行命令"不构成豁免，
/// 否则幻觉门控直接失效。
///
/// 判据刻意保守：否定词必须**直接**修饰无限定的"命令/指令"。
/// "禁止执行安装命令""不要运行任何修改类命令"只禁止某一类命令
/// （只读命令仍然该跑），限定词落在修饰槽位之外，因此不会命中。
class NoCommandIntentDetector {
  /// 否定词 + 可选动词 + 可选限定词 + 命令。
  /// `(?!行)` 排除"命令行"（如"不需要命令行工具"）。
  static final RegExp _zhPattern = RegExp(
    r'(?:严禁|严格禁止|禁止|不准|不许|不可|不得|不要|请勿|无需|无须|不需要|不必|不用)'
    r'(?:再|也|直接|就地)?'
    r'(?:执行|运行|调用|发起|发出|使用|采用|跑|动用)?'
    r'(?:任何|一切|任意|额外的|新的|别的|其他的)?'
    r'(?:\s*shell\s*)?'
    r'\s*(?:命令|指令)(?!行)',
  );

  /// `别` 必须带动词，避免"特别命令""级别命令"误判。
  static final RegExp _zhBiePattern = RegExp(
    r'别\s*(?:执行|运行|调用|跑)\s*(?:任何|一切)?\s*(?:\s*shell\s*)?\s*(?:命令|指令)(?!行)',
  );

  /// `(?![-\w])` 挡掉 "command-line" 这类无关写法。
  static final RegExp _enPattern = RegExp(
    r"(?:don'?t|do\s+not|does\s+not|never|without|avoid)\s+"
    r"(?:execut\w*|run(?:ning)?|issu\w*|invok\w*|us(?:e|ing)|send(?:ing)?)?\s*"
    r"(?:any|further|more|additional|extra)?\s*"
    r"(?:shell\s*)?"
    r"(?:command|instruction)s?\b(?![-\w])",
    caseSensitive: false,
  );

  /// 返回 true 表示用户显式要求本次任务不要执行命令。
  static bool detects(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    return _zhPattern.hasMatch(trimmed) ||
        _zhBiePattern.hasMatch(trimmed) ||
        _enPattern.hasMatch(trimmed);
  }
}
