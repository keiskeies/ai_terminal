class AnsiStripper {
  /// 匹配所有 ANSI 转义序列的正则表达式
  /// 涵盖：CSI 序列（含 ? > ! 等私有参数）、OSC 序列、字符集选择、两字节序列、BEL、CR
  /// CSI 格式：ESC [ <参数字节 0x20-0x3F>* <终止字节 0x40-0x7E>
  static final RegExp _ansiRegex = RegExp(
    r'\x1B\[[\x20-\x3F]*[\x40-\x7E]' // CSI: ESC [ 参数字节 终止字节
    r'|\x1B\][0-9]*;?[^\x07\x1B]*(?:\x07|\x1B\\)' // OSC
    r'|\x1B[(][A-Za-z]' // Charset: ESC ( letter
    r'|\x1B[)][A-Za-z]' // Charset: ESC ) letter
    r'|\x1B[A-Za-z]' // Other 2-byte: ESC letter
    r'|\x07' // BEL
    r'|\x0D', // CR
  );

  /// 清理残留的半截序列（ESC 字符丢失后的残留）
  /// 例如：]0;root@host:~  (OSC 标题设置的残留)
  ///
  /// 必须要求至少一位数字：`\][0-9]*;` 会命中 `arr[0]; done` 的 `];`
  /// （零位数字），把合法文本整行吃掉。
  static final RegExp _residualOsc = RegExp(r'\][0-9]+;[^\n\r]*');

  /// 清理残留的 CSI 参数片段
  /// 例如：[0m、[?2004h/[?2004l（括号粘贴模式）、[>0;10;1c 等
  ///
  /// 参数段限定 ECMA-48 参数字节 0x30-0x3F（数字与 :;<=>?），终止字节限定
  /// 字母/@。放宽到 0x20-0x3F 会把 `,`/`-` 当参数，`[1,2,3]`、`[2026-11-19]`
  /// 这类合法输出会被整段删掉（探针实证）。裸 `[K` 无参数不再清——代价是
  /// 极端 ESC 丢失场景留噪声，不损坏文本。
  static final RegExp _residualCsi = RegExp(r'\[[\x30-\x3F]+[A-Za-z@]');

  /// 清理控制字符（除 \n \t 外）和行尾空格，一遍完成
  static final RegExp _controlCharsAndTrailingSpaces = RegExp(
    r'[\x00-\x08\x0B\x0C\x0E-\x1F]| +$',
    multiLine: true,
  );

  /// 连续空行最多保留一个
  static final RegExp _repeatedBlankLines = RegExp(r'\n{3,}');

  /// 行首的 prompt 残留（如 [root@host ~]#）
  static final RegExp _promptPrefix = RegExp(
    r'^\[[\w@.\-~\s]+\][#$]\s*',
    multiLine: true,
  );

  /// 清理 ANSI 转义序列，返回纯文本
  static String strip(String input) {
    var result = input;

    // 1. 移除完整的 ANSI 转义序列
    result = result.replaceAll(_ansiRegex, '');

    // 2. 行首 prompt 残留必须在残留 CSI 清理之前处理：
    //    `[root@host ~]# ` 会被 `\[[\x20-\x3F]*[\x40-\x7E]` 误认成 `[r` 片段，
    //    先删 prompt 才能整行删掉。
    result = result.replaceAll(_promptPrefix, '');

    // 3. 清理残留的半截 OSC / CSI 片段——仅当原始输入确实含转义字节。
    //    残留的前提是 ESC 丢失；没有 ESC 的输入不存在残留，无条件清洗只会
    //    毁掉 `[INFO]`、JSON 数组、`[2026-11-19]` 时间戳等合法文本（探针实证）。
    if (input.contains('\x1B') || input.contains('\x07')) {
      result = result.replaceAll(_residualOsc, '');
      result = result.replaceAll(_residualCsi, '');
    }

    // 4. 控制字符 + 行尾空格（合并为一遍）
    result = result.replaceAll(_controlCharsAndTrailingSpaces, '');

    // 5. 连续空行（最多保留一个）
    result = result.replaceAll(_repeatedBlankLines, '\n\n');

    return result.trim();
  }
}
