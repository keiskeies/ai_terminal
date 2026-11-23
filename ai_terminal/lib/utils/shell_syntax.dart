/// 命令闭合预检：在把命令交给 shell 之前，静态检测明显的引号 / 圆括号 / heredoc 未闭合。
///
/// 目的：把「未闭合命令进入 PTY → shell 进入 PS2 等待输入 → 干等超时」这条卡死路径，
/// 在执行前转成一条明确的 syntaxError，让 AI 有机会自我修正。
///
/// 保守原则：只在能确定未闭合时返回原因；拿不准一律放行，由下游 PtyOutputDetector /
/// 超时逻辑兜底。误报会拦掉合法命令，代价远高于漏报。
class ShellSyntax {
  ShellSyntax._();

  /// heredoc 起始标记：<<-? 空白? 引号? TAG 引号?（引号反向引用保证配对）
  static final RegExp _heredocStart =
      RegExp(r'''<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1''');

  /// 返回未闭合原因（中文，可直接进观测回灌）；null 表示闭合 / 无需检查。
  ///
  /// [isWindows] 为 true 时直接放行：cmd / PowerShell 的转义与引号规则不同。
  static String? unclosedReason(String command, {bool isWindows = false}) {
    if (isWindows) return null;
    final text = command.trim();
    if (text.isEmpty) return null;

    final lines = text.split('\n');

    // 1. 先定位 heredoc body（起始行之后到结束定界符的行），避免 body 内的
    //    引号 / 括号干扰主扫描；同时检测定界符是否缺失。
    final bodyLines = <int>{};
    for (var i = 0; i < lines.length; i++) {
      final m = _firstHeredocOnLine(lines[i]);
      if (m == null) continue;
      final tag = m.group(2)!;
      var found = false;
      for (var j = i + 1; j < lines.length; j++) {
        if (lines[j].trim() == tag) {
          found = true;
          for (var k = i + 1; k <= j; k++) {
            bodyLines.add(k);
          }
          break;
        }
      }
      if (!found) return 'heredoc 定界符 $tag 缺少结束行';
    }

    // 2. 主扫描：单/双引号、反引号、圆括号（含 $( )。方括号/花括号不查——
    //    test 的 [ ]、${VAR}、brace expansion 太容易误报。
    var single = false;
    var double = false;
    var backtick = false;
    var escaped = false;
    final parens = <int>[];

    for (var i = 0; i < lines.length; i++) {
      if (bodyLines.contains(i)) continue;
      final line = lines[i];
      var inComment = false;

      for (var j = 0; j < line.length; j++) {
        final c = line[j];

        if (inComment) continue;
        if (escaped) {
          escaped = false;
          continue;
        }

        if (single) {
          if (c == "'") single = false; // POSIX 单引号内反斜杠是字面量
          continue;
        }
        if (backtick) {
          if (c == '\\') {
            escaped = true;
          } else if (c == '`') {
            backtick = false;
          }
          continue;
        }
        if (double) {
          if (c == '\\') {
            escaped = true;
          } else if (c == '"') {
            double = false;
          } else if (c == '\$' && j + 1 < line.length && line[j + 1] == '(') {
            parens.add(j); // 双引号内的命令替换括号也要配对
          } else if (c == ')' && parens.isNotEmpty) {
            parens.removeLast();
          }
          continue;
        }

        // 引号外
        if (c == '#' && line.substring(0, j).trim().isEmpty) {
          inComment = true; // 行首注释
          continue;
        }
        if (c == '\\') {
          escaped = true;
        } else if (c == "'") {
          single = true;
        } else if (c == '"') {
          double = true;
        } else if (c == '`') {
          backtick = true;
        } else if (c == '(') {
          parens.add(j);
        } else if (c == ')') {
          // 裸 ')' 可能是 case 分支等合法语法，不把「多余闭合」当错误
          if (parens.isNotEmpty) parens.removeLast();
        }
      }
    }

    if (single) return '单引号未闭合';
    if (double) return '双引号未闭合';
    if (backtick) return '反引号未闭合';
    if (parens.isNotEmpty) return '圆括号未闭合';
    return null;
  }

  /// 取一行里第一个合法的 heredoc 起始匹配；排除 <<< here-string、$(( 移位，
  /// 以及引号内 / 行首注释里的 `<<TAG`（如 `echo "<<EOF demo"` —— 它不是 heredoc）。
  static RegExpMatch? _firstHeredocOnLine(String line) {
    final matches = _heredocStart.allMatches(line);
    for (final m in matches) {
      if (m.start > 0 && line[m.start - 1] == '<') continue; // <<<
      final end = m.end;
      if (end < line.length && !' \t;|&\r'.contains(line[end])) continue;
      if (_isQuotedOrCommentAt(line, m.start)) continue;
      return m;
    }
    return null;
  }

  /// 位置 [pos] 是否处于引号内或行首注释中（只扫本行，跨行引号本就无法可靠判定）。
  /// heredoc 定界符必须写在 shell 的"命令位置"，出现在引号/注释里只是普通文本。
  static bool _isQuotedOrCommentAt(String line, int pos) {
    var single = false;
    var double = false;
    var escaped = false;
    for (var i = 0; i < pos; i++) {
      final c = line[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (single) {
        if (c == "'") single = false;
        continue;
      }
      if (double) {
        if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          double = false;
        }
        continue;
      }
      if (c == r'\') {
        escaped = true;
      } else if (c == "'") {
        single = true;
      } else if (c == '"') {
        double = true;
      } else if (c == '#' && line.substring(0, i).trim().isEmpty) {
        return true; // 行首注释
      }
    }
    return single || double;
  }
}
