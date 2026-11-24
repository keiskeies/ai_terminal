/// 命令闭合预检：在把命令交给 shell 之前，静态检测明显的引号 / 圆括号 / heredoc 未闭合。
///
/// 目的：把「未闭合命令进入 PTY → shell 进入 PS2 等待输入 → 干等超时」这条卡死路径，
/// 在执行前转成一条明确的 syntaxError，让 AI 有机会自我修正。
///
/// 保守原则：只在能确定未闭合时返回原因；拿不准一律放行，由下游 PtyOutputDetector /
/// 超时逻辑兜底。误报会拦掉合法命令，代价远高于漏报。
class ShellSyntax {
  ShellSyntax._();

  /// POSIX 退出码包装前的共享可靠性扫描。
  ///
  /// 本地 PTY、SSH 与多机预检必须使用同一结果，避免某条入口能派发后台命令或
  /// 末尾续行，而另一条入口把它拦在执行器外。反斜杠换行按 POSIX 词法规则先移除，
  /// 且不会把转义状态错误带到下一物理行。
  static PosixCommandScan scanPosixCommand(String command) {
    final lines = command.split('\n');
    final bodyLines = _analyzeHeredocs(lines).bodyLines;
    var line = 0;
    var inBody = bodyLines.contains(0);
    var single = false;
    var double = false;
    var backtick = false;
    var escaped = false;
    var inComment = false;
    var arithmeticDepth = 0;
    var hasBackground = false;
    String? trailingOperator;
    int? danglingContinuationLine;
    final comments = <int, int>{};

    for (var i = 0; i < command.length; i++) {
      final c = command[i];
      if (c == '\n') {
        line++;
        inBody = bodyLines.contains(line);
        inComment = false;
        escaped = false;
        continue;
      }
      if (inBody) continue;

      if (inComment) {
        if (c == r'\') {
          final continuation = _continuationLength(command, i);
          if (continuation > 0) {
            i += continuation - 1;
            line++;
            inBody = bodyLines.contains(line);
          } else if (_isFinalBackslash(command, i)) {
            danglingContinuationLine = line;
          }
        }
        continue;
      }
      if (escaped) {
        escaped = false;
        trailingOperator = null; // 转义后的运算符/空白是词的一部分，不是悬空运算符。
        continue;
      }
      // 反斜杠换行在引号/注释识别前移除；单引号与注释里的续行也不能把状态
      // 带到下一行。heredoc body 是原文，不执行此折叠。
      if (c == r'\') {
        final continuation = _continuationLength(command, i);
        if (continuation > 0) {
          i += continuation - 1;
          line++;
          inBody = bodyLines.contains(line);
          continue;
        }
      }

      if (single) {
        if (c == "'") single = false;
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
        } else if (c == '`') {
          backtick = true;
        } else if (c == '(' &&
            i + 1 < command.length &&
            command[i + 1] == '(') {
          arithmeticDepth++;
          i++;
        } else if (c == ')' &&
            i + 1 < command.length &&
            command[i + 1] == ')' &&
            arithmeticDepth > 0) {
          arithmeticDepth--;
          i++;
        }
        continue;
      }

      if (c == '\\') {
        escaped = true;
        if (_isFinalBackslash(command, i)) danglingContinuationLine = line;
      } else if (c == "'") {
        trailingOperator = null;
        single = true;
      } else if (c == '"') {
        trailingOperator = null;
        double = true;
      } else if (c == '`') {
        trailingOperator = null;
        backtick = true;
      } else if (c == '#' &&
          (i == 0 || ' \t;|&()\n\r'.contains(command[i - 1]))) {
        comments[line] = i;
        inComment = true;
      } else if (c == '(' && i + 1 < command.length && command[i + 1] == '(') {
        trailingOperator = '(';
        arithmeticDepth++;
        i++;
      } else if (c == ')' &&
          i + 1 < command.length &&
          command[i + 1] == ')' &&
          arithmeticDepth > 0) {
        trailingOperator = null;
        arithmeticDepth--;
        i++;
      } else if (c == '(') {
        trailingOperator = '(';
      } else if (c == ')') {
        trailingOperator = null;
      } else if ('&|<>'.contains(c)) {
        trailingOperator = '${trailingOperator ?? ''}$c';
        if (c == '&') {
          final previous = i > 0 ? command[i - 1] : '';
          final next = i + 1 < command.length ? command[i + 1] : '';
          if (previous != '<' &&
              previous != '>' &&
              previous != '&' &&
              previous != '|' &&
              next != '&' &&
              next != '>' &&
              arithmeticDepth == 0) {
            hasBackground = true;
          }
        }
      } else if (c != ' ' && c != '\t' && c != '\r') {
        trailingOperator = null;
      }
    }
    const operatorsRequiringRhs = {
      '&&',
      '||',
      '|',
      '|&',
      '&',
      '<',
      '>',
      '<<',
      '<<<',
      '>>',
      '>>>',
      '<>',
      '>&',
      '<&',
      '>|',
      '(',
    };
    return PosixCommandScan._(
      hasBackgroundOperator: hasBackground,
      commentStart: comments[0],
      danglingContinuationLine: danglingContinuationLine,
      incompleteCommentPrefix: comments[0] != null &&
          operatorsRequiringRhs.contains(trailingOperator),
    );
  }

  static int _continuationLength(String command, int slash) {
    if (slash + 1 >= command.length) return 0;
    if (command[slash + 1] == '\n') return 2;
    if (slash + 2 < command.length &&
        command[slash + 1] == '\r' &&
        command[slash + 2] == '\n') {
      return 3;
    }
    return 0;
  }

  static bool _isFinalBackslash(String command, int slash) {
    var end = slash + 1;
    if (end < command.length && command[end] == '\r') end++;
    return end == command.length;
  }

  /// heredoc 起始标记：<<-? 空白? 引号? TAG 引号?（引号反向引用保证配对）
  static final RegExp _heredocStart =
      RegExp(r'''(<<(-)?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\3''');

  /// 返回未闭合原因（中文，可直接进观测回灌）；null 表示闭合 / 无需检查。
  ///
  /// [isWindows] 为 true 时直接放行：cmd / PowerShell 的转义与引号规则不同。
  static String? unclosedReason(String command, {bool isWindows = false}) {
    if (isWindows) return null;
    if (command.trim().isEmpty) return null;

    // 不能 trim 后拆分：末尾空格可能是 heredoc 正文/结束行的一部分，
    // trim 会把非法的 `EOF   ` 伪造成合法结束行。
    final lines = command.split('\n');

    // 1. 先定位 heredoc body（起始行之后到结束定界符的行），避免 body 内的
    //    引号 / 括号干扰主扫描；同时检测定界符是否缺失。
    final heredocs = _analyzeHeredocs(lines);
    if (heredocs.missingTag != null) {
      return 'heredoc 定界符 ${heredocs.missingTag} 缺少结束行';
    }
    final bodyLines = heredocs.bodyLines;

    // 2. 主扫描：每个 $() 都有独立引号/转义/注释上下文。双引号里的单引号只是
    //    普通字符，而进入 $(...) 后它可能开启子 shell 的单引号；共用一组布尔值
    //    会把 `echo "$(printf '"')"` 的外层双引号错误闭合。
    final contexts = <_ShellLexicalFrame>[_ShellLexicalFrame()];

    for (var i = 0; i < lines.length; i++) {
      if (bodyLines.contains(i)) continue;
      final line = lines[i];
      for (final context in contexts) {
        context.escaped = false;
        context.inComment = false;
      }

      for (var j = 0; j < line.length; j++) {
        final c = line[j];
        final context = contexts.last;
        if (context.inComment) continue;
        if (context.escaped) {
          context.escaped = false;
          continue;
        }

        if (context.quote == _ShellQuote.single) {
          if (c == "'") context.quote = _ShellQuote.none;
          continue;
        }
        if (context.quote == _ShellQuote.backtick) {
          if (c == '\\') {
            context.escaped = true;
          } else if (c == '`') {
            context.quote = _ShellQuote.none;
          }
          continue;
        }
        if (context.quote == _ShellQuote.double) {
          if (c == '\\') {
            context.escaped = true;
          } else if (c == '"') {
            context.quote = _ShellQuote.none;
          } else if (c == r'$' && j + 1 < line.length && line[j + 1] == '(') {
            contexts.add(_ShellLexicalFrame());
            j++;
          }
          continue;
        }

        // 引号外（root 或某个 $() 子上下文）
        if (c == '#' && (j == 0 || ' \t;|&()'.contains(line[j - 1]))) {
          context.inComment = true;
          continue;
        }
        if (c == '\\') {
          context.escaped = true;
        } else if (c == "'") {
          context.quote = _ShellQuote.single;
        } else if (c == '"') {
          context.quote = _ShellQuote.double;
        } else if (c == '`') {
          context.quote = _ShellQuote.backtick;
        } else if (c == r'$' && j + 1 < line.length && line[j + 1] == '(') {
          contexts.add(_ShellLexicalFrame());
          j++;
        } else if (c == '(') {
          context.parenDepth++;
        } else if (c == ')') {
          // 裸 ')' 可能是 case 分支等合法语法，不把「多余闭合」当错误。
          if (context.parenDepth > 0) {
            context.parenDepth--;
          } else if (contexts.length > 1) {
            contexts.removeLast();
          }
        }
      }
      // 反斜杠换行会被 shell 移除，不转义下一行的首个字符；引号与 $() 则继续跨行。
    }

    // `$(` 未闭合时，优先报圆括号；但若子上下文里开了单引号，单引号
    // 错误更具体（外层双引号内的 `'` 不会自行闭合），仍保留单引号提示。
    final hasUnclosedSubstitution = contexts.length > 1;
    final hasUnclosedSingle =
        contexts.any((context) => context.quote == _ShellQuote.single);
    if (hasUnclosedSubstitution && !hasUnclosedSingle) {
      return '圆括号未闭合';
    }

    for (final context in contexts.reversed) {
      if (context.quote == _ShellQuote.single) return '单引号未闭合';
      if (context.quote == _ShellQuote.double) return '双引号未闭合';
      if (context.quote == _ShellQuote.backtick) return '反引号未闭合';
    }
    if (contexts.length > 1 ||
        contexts.any((context) => context.parenDepth > 0)) {
      return '圆括号未闭合';
    }
    return null;
  }

  /// heredoc body/结束行集合，供退出码包装器等 shell 扫描器排除纯文本区域。
  static Set<int> heredocBodyLines(List<String> lines) =>
      _analyzeHeredocs(lines).bodyLines;

  /// 跨行流式 heredoc 识别：调用方逐行喂入命令字段，得到该行全部合法起始。
  /// body 行不应喂入（heredoc 正文是原文，不参与词法状态）。
  static List<({String tag, bool stripTabs})> heredocTagsOnLine(
      String line, ShellHeredocScanner scanner) {
    return [
      for (final m in _heredocsOnLine(line, scanner._context))
        (tag: m.group(4)!, stripTabs: m.group(2) != null),
    ];
  }

  /// heredoc 结束行判定：普通 `<<TAG` 精确匹配；`<<-TAG` 允许前导 tab。
  static bool isHeredocTerminator(String line, String tag,
          {bool stripTabs = false}) =>
      _isHeredocTerminator(line, tag, stripTabs);

  static ({Set<int> bodyLines, String? missingTag}) _analyzeHeredocs(
      List<String> lines) {
    final bodyLines = <int>{};
    final quoteContext = _QuoteContext();
    for (var i = 0; i < lines.length; i++) {
      if (bodyLines.contains(i)) continue;
      final matches = _heredocsOnLine(lines[i], quoteContext);
      if (matches.isEmpty) continue;
      // POSIX 按起始行中出现的顺序消费多个 heredoc：第一个 body/结束行之后，
      // 才是第二个 tag 的 body。逐个查找，避免 `cat <<A <<B` 只校验 A。
      var searchFrom = i + 1;
      for (final m in matches) {
        final tag = m.group(4)!;
        final stripTabs = m.group(2) != null;
        var end = searchFrom;
        while (end < lines.length &&
            !_isHeredocTerminator(lines[end], tag, stripTabs)) {
          end++;
        }
        if (end == lines.length) {
          return (bodyLines: bodyLines, missingTag: tag);
        }
        for (var k = searchFrom; k <= end; k++) {
          bodyLines.add(k);
        }
        searchFrom = end + 1;
      }
    }
    return (bodyLines: bodyLines, missingTag: null);
  }

  /// 普通 `<<TAG` 的结束行必须精确等于 TAG；只有 `<<-TAG` 允许行首 tab。
  /// 空格缩进与尾随空白都不属于定界符，否则会把真实正文误当成结束行。
  static bool _isHeredocTerminator(String line, String tag, bool stripTabs) {
    final withoutCr =
        line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
    if (!stripTabs) return withoutCr == tag;
    var start = 0;
    while (start < withoutCr.length && withoutCr[start] == '\t') {
      start++;
    }
    return withoutCr.substring(start) == tag;
  }

  /// 取一行里所有合法的 heredoc 起始匹配；排除 <<< here-string、$(( 移位，
  /// 以及引号内 / 行首注释里的 `<<TAG`（如 `echo "<<EOF demo"` —— 它不是 heredoc）。
  ///
  /// [context] 跨非 body 行保留：单双引号、反引号命令替换、`$()` 与 `$(( ))`
  /// 各自入栈，确保 heredoc 只在真正会执行到它的词法层里登记。
  static List<Match> _heredocsOnLine(String line, _QuoteContext context) {
    final matches = <Match>[];
    var inComment = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      final frame = context.frame;
      if (inComment) {
        frame.escaped = false;
        continue;
      }
      if (frame.escaped) {
        frame.escaped = false;
        continue;
      }
      if (frame.single) {
        if (c == "'") frame.single = false;
        continue;
      }
      switch (frame.kind) {
        case _HeredocFrameKind.double:
          if (c == r'\') {
            frame.escaped = true;
          } else if (c == '"') {
            context.pop();
          } else if (c == r'$' && i + 1 < line.length && line[i + 1] == '(') {
            if (i + 2 < line.length && line[i + 2] == '(') {
              context.push(_HeredocFrameKind.arithmetic);
              i += 2;
            } else {
              context.push(_HeredocFrameKind.substitution);
              i++;
            }
          } else if (c == '`') {
            context.push(_HeredocFrameKind.backtick);
          }
          continue;
        case _HeredocFrameKind.backtick:
          if (c == r'\') {
            frame.escaped = true;
          } else if (c == '`') {
            context.pop();
          } else if (c == "'") {
            frame.single = true;
          } else if (c == '"') {
            context.push(_HeredocFrameKind.double);
          } else if (c == r'$' && i + 1 < line.length && line[i + 1] == '(') {
            if (i + 2 < line.length && line[i + 2] == '(') {
              context.push(_HeredocFrameKind.arithmetic);
              i += 2;
            } else {
              context.push(_HeredocFrameKind.substitution);
              i++;
            }
          } else if (c == '<' && i + 1 < line.length && line[i + 1] == '<') {
            i = _collectHeredoc(line, i, matches);
          }
          continue;
        case _HeredocFrameKind.arithmetic:
          if (c == r'\') {
            frame.escaped = true;
          } else if (c == r'$' && i + 1 < line.length && line[i + 1] == '(') {
            if (i + 2 < line.length && line[i + 2] == '(') {
              context.push(_HeredocFrameKind.arithmetic);
              i += 2;
            } else {
              context.push(_HeredocFrameKind.substitution);
              i++;
            }
          } else if (c == '(') {
            frame.parenDepth++;
          } else if (c == ')') {
            if (frame.parenDepth > 0) {
              frame.parenDepth--;
            } else {
              context.pop();
            }
          }
          continue;
        case _HeredocFrameKind.substitution:
        case _HeredocFrameKind.root:
          if (c == r'\') {
            frame.escaped = true;
          } else if (c == "'") {
            frame.single = true;
          } else if (c == '"') {
            context.push(_HeredocFrameKind.double);
          } else if (c == '`') {
            context.push(_HeredocFrameKind.backtick);
          } else if (c == '#' && (i == 0 || ' \t;|&()'.contains(line[i - 1]))) {
            inComment = true;
          } else if (c == r'$' && i + 1 < line.length && line[i + 1] == '(') {
            if (i + 2 < line.length && line[i + 2] == '(') {
              context.push(_HeredocFrameKind.arithmetic);
              i += 2;
            } else {
              context.push(_HeredocFrameKind.substitution);
              i++;
            }
          } else if (c == '(') {
            frame.parenDepth++;
          } else if (c == ')') {
            if (frame.parenDepth > 0) {
              frame.parenDepth--;
            } else if (frame.kind == _HeredocFrameKind.substitution &&
                context.stack.length > 1) {
              context.pop();
            }
          } else if (c == '<' && i + 1 < line.length && line[i + 1] == '<') {
            i = _collectHeredoc(line, i, matches);
          }
      }
    }
    // POSIX 反斜杠换行是续行，不把转义状态带到下一行；引号则继续跨行。
    for (final frame in context.stack) {
      frame.escaped = false;
    }
    return matches;
  }

  /// 从 [i] 处的 `<<` 收集合法 heredoc 起始，返回应继续扫描的下标。
  /// 返回值小于 [i] 表示未识别（调用方按普通字符继续）。
  static int _collectHeredoc(String line, int i, List<Match> matches) {
    final m = _heredocStart.matchAsPrefix(line, i);
    if (m == null) return i;
    if (i > 0 && line[i - 1] == '<') return i; // <<<
    final end = m.end;
    if (end < line.length && !' \t;|&\r'.contains(line[end])) return i;
    matches.add(m);
    return end - 1; // 引号包裹的 TAG 是操作符的一部分，不参与引号状态切换
  }
}

/// POSIX 命令的静态扫描结果；[reliabilityReason] 是退出码包装与多机预检的共享门禁。
class PosixCommandScan {
  const PosixCommandScan._({
    required this.hasBackgroundOperator,
    required this.commentStart,
    required this.danglingContinuationLine,
    this.incompleteCommentPrefix = false,
  });

  final bool hasBackgroundOperator;
  final int? commentStart;
  final int? danglingContinuationLine;
  final bool incompleteCommentPrefix;

  String? get reliabilityReason {
    if (incompleteCommentPrefix) {
      return '行尾注释前的命令以需要右值的运算符结尾，无法安全追加退出码标记';
    }
    if (hasBackgroundOperator) {
      return '后台命令无法可靠获取退出码，请改为前台执行';
    }
    if (danglingContinuationLine != null) {
      return '命令末尾反斜杠续行未闭合';
    }
    return null;
  }
}

enum _ShellQuote { none, single, double, backtick }

/// 一个 shell 词法层；`$()` 会入栈一个新层，闭合后恢复父层的引号状态。
class _ShellLexicalFrame {
  _ShellQuote quote = _ShellQuote.none;
  bool escaped = false;
  bool inComment = false;
  int parenDepth = 0;
}

/// 流式 heredoc 识别状态；一个命令字段一个实例。
class ShellHeredocScanner {
  final _QuoteContext _context = _QuoteContext();
}

/// heredoc 起始识别所需的跨行 shell 词法上下文。
class _QuoteContext {
  final List<_HeredocFrame> stack = [_HeredocFrame(_HeredocFrameKind.root)];

  _HeredocFrame get frame => stack.last;

  void push(_HeredocFrameKind kind) => stack.add(_HeredocFrame(kind));

  void pop() {
    if (stack.length > 1) stack.removeLast();
  }
}

enum _HeredocFrameKind { root, double, backtick, substitution, arithmetic }

class _HeredocFrame {
  _HeredocFrame(this.kind);

  final _HeredocFrameKind kind;
  bool single = false;
  bool escaped = false;
  int parenDepth = 0;
}
