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
  static final RegExp _residualOsc = RegExp(r'\][0-9]*;[^\n\r]*');

  /// 清理残留的 CSI 参数片段
  /// 例如：[K (清除行)、[?2004h/[?2004l (括号粘贴模式)、[>0;10;1c 等
  static final RegExp _residualCsi = RegExp(r'\[[\x20-\x3F]*[\x40-\x7E]');

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

    // 3. 清理残留的半截 OSC / CSI 片段
    result = result.replaceAll(_residualOsc, '');
    result = result.replaceAll(_residualCsi, '');

    // 4. 控制字符 + 行尾空格（合并为一遍）
    result = result.replaceAll(_controlCharsAndTrailingSpaces, '');

    // 5. 连续空行（最多保留一个）
    result = result.replaceAll(_repeatedBlankLines, '\n\n');

    return result.trim();
  }
}
