enum CommandShell { posix, powershell, cmd, unknown }

enum CommandEffect {
  privilegeEscalation,
  environmentModification,
  processControl,
  inputRedirect,
  outputRedirect,
  pipeline,
  dynamicInvocation,
}

class UnresolvedConstruct {
  final String kind;
  final String detail;

  const UnresolvedConstruct(this.kind, this.detail);
}

class CommandIntent {
  final String shell;
  final String? executable;
  final List<String> arguments;
  final String? cwd;
  final Map<String, String> environment;
  final List<CommandEffect> effects;
  final List<UnresolvedConstruct> unresolved;
  final double confidence;
  final bool conservativeSafe;

  const CommandIntent({
    required this.shell,
    required this.executable,
    required this.arguments,
    required this.cwd,
    required this.environment,
    required this.effects,
    required this.unresolved,
    required this.confidence,
    required this.conservativeSafe,
  });
}

/// 保守分词器，不尝试成为完整 shell AST。无法证明只读的命令一律给出否定结论。
class CommandIntentParser {
  static const parserVersion = '1';

  static const _posixReadOnly = {
    'basename',
    'cat',
    'cut',
    'date',
    'df',
    'dirname',
    'du',
    'echo',
    'env',
    'file',
    'free',
    'getent',
    'grep',
    'head',
    'hostname',
    'id',
    'ip',
    'jq',
    'last',
    'less',
    'ls',
    'md5sum',
    'more',
    'netstat',
    'printf',
    'ps',
    'pwd',
    'readlink',
    'realpath',
    'sed',
    'sort',
    'ss',
    'stat',
    'tail',
    'top',
    'tr',
    'uname',
    'uniq',
    'uptime',
    'wc',
    'whereis',
    'which',
    'who',
    'whoami',
  };

  static const _powershellReadOnly = {
    'convertto-json',
    'format-list',
    'format-table',
    'get-childitem',
    'get-command',
    'get-computerinfo',
    'get-content',
    'get-date',
    'get-help',
    'get-history',
    'get-item',
    'get-location',
    'get-netipaddress',
    'get-partition',
    'get-process',
    'get-service',
    'get-volume',
    'group-object',
    'measure-object',
    'resolve-path',
    'select-object',
    'select-string',
    'sort-object',
    'test-path',
    'where-object',
    'write-host',
    'write-output',
  };

  static const _cmdReadOnly = {
    'cd',
    'chdir',
    'dir',
    'echo',
    'find',
    'findstr',
    'hostname',
    'ipconfig',
    'path',
    'tasklist',
    'tree',
    'type',
    'ver',
    'where',
    'whoami',
  };

  static CommandIntent parse(String raw) {
    final effects = <CommandEffect>{};
    final unresolved = <UnresolvedConstruct>[];
    final environment = <String, String>{};
    final segments = _segments(raw, unresolved);
    var allSafe = segments.isNotEmpty;
    String? firstExecutable;
    List<String> firstArguments = [];
    CommandShell? detectedShell;

    for (final segment in segments) {
      final result = _parseSegment(segment, effects, unresolved, environment);
      if (result.executable != null && firstExecutable == null) {
        firstExecutable = result.executable;
        firstArguments = result.arguments;
      }
      allSafe = allSafe && result.safe;
      detectedShell ??= result.shell;
    }

    final confidence = unresolved.isEmpty
        ? (allSafe ? 0.95 : 0.75)
        : (0.5 - 0.05 * unresolved.length).clamp(0.1, 0.5);
    return CommandIntent(
      shell: (detectedShell ?? CommandShell.unknown).name,
      executable: firstExecutable,
      arguments: firstArguments,
      cwd: null,
      environment: Map.unmodifiable(environment),
      effects: List.unmodifiable(effects),
      unresolved: List.unmodifiable(unresolved),
      confidence: confidence.toDouble(),
      conservativeSafe: allSafe &&
          unresolved.isEmpty &&
          !effects.any((e) =>
              e == CommandEffect.outputRedirect ||
              e == CommandEffect.privilegeEscalation ||
              e == CommandEffect.environmentModification ||
              e == CommandEffect.processControl ||
              e == CommandEffect.dynamicInvocation),
    );
  }

  static _SegmentResult _parseSegment(
    String segment,
    Set<CommandEffect> effects,
    List<UnresolvedConstruct> unresolved,
    Map<String, String> environment,
  ) {
    final tokens = _tokens(segment, unresolved, effects);
    if (tokens.isEmpty) {
      return const _SegmentResult(null, const [], CommandShell.unknown, true);
    }
    final shell = _shellFor(tokens.first);
    return _parseTokens(
      tokens,
      shell,
      effects,
      unresolved,
      environment,
      allowRecursion: true,
    );
  }

  static _SegmentResult _parseTokens(
    List<String> tokens,
    CommandShell shell,
    Set<CommandEffect> effects,
    List<UnresolvedConstruct> unresolved,
    Map<String, String> environment, {
    required bool allowRecursion,
  }) {
    var index = 0;
    while (index < tokens.length && _isAssignment(tokens[index])) {
      final assignment = tokens[index++];
      final equals = assignment.indexOf('=');
      environment[assignment.substring(0, equals)] =
          assignment.substring(equals + 1);
      effects.add(CommandEffect.environmentModification);
    }
    if (index >= tokens.length) {
      return const _SegmentResult(null, const [], CommandShell.unknown, false);
    }

    var executable = _commandName(tokens[index++]);
    var arguments = tokens.sublist(index);
    if (executable.isEmpty ||
        executable.contains('=') ||
        executable.startsWith('-')) {
      return _SegmentResult(executable, arguments, shell, false);
    }

    if (_isInterpreterWithCode(executable, arguments)) {
      unresolved.add(UnresolvedConstruct(
          'interpreter_code', '$executable 执行内联代码或脚本，无法静态证明只读'));
      return _SegmentResult(executable, arguments, shell, false);
    }

    if (_isPowerShell(executable)) {
      detectedPowerShell(executable, arguments, effects, unresolved);
      final commandIndex = _powerShellCommandIndex(arguments);
      if (commandIndex < 0) {
        return _SegmentResult(
            executable, arguments, CommandShell.powershell, false);
      }
      final inner = _stripOuterQuotes(arguments[commandIndex]);
      if (inner.isEmpty) {
        unresolved
            .add(const UnresolvedConstruct('empty_command', 'PowerShell 命令为空'));
        return _SegmentResult(
            executable, arguments, CommandShell.powershell, false);
      }
      if (!allowRecursion) {
        return _SegmentResult(
            executable, arguments, CommandShell.powershell, false);
      }
      return _parseTokens(
        _tokens(inner, unresolved, effects),
        CommandShell.powershell,
        effects,
        unresolved,
        environment,
        allowRecursion: false,
      );
    }

    if (_isCmd(executable)) {
      if (!arguments.contains('/c') && !arguments.contains('/C')) {
        return _SegmentResult(executable, arguments, CommandShell.cmd, false);
      }
      unresolved.add(
          const UnresolvedConstruct('cmd_interpreter', 'cmd /c 的变量与链式语义未完整解析'));
      return _SegmentResult(executable, arguments, CommandShell.cmd, false);
    }

    if (executable == '&') {
      effects.add(CommandEffect.dynamicInvocation);
      return _parseTokens(
        arguments,
        CommandShell.powershell,
        effects,
        unresolved,
        environment,
        allowRecursion: false,
      );
    }

    if (_isWrapper(executable)) {
      final innerIndex = _wrapperCommandIndex(executable, arguments, effects);
      if (innerIndex < 0) {
        unresolved.add(UnresolvedConstruct(
            'unknown_wrapper', '$executable 包装器的目标命令无法可靠解析'));
        return _SegmentResult(executable, arguments, shell, false);
      }
      final innerTokens = arguments.sublist(innerIndex);
      final inner = _parseTokens(
        innerTokens,
        shell,
        effects,
        unresolved,
        environment,
        allowRecursion: false,
      );
      return _SegmentResult(
        inner.executable,
        inner.arguments,
        inner.shell,
        false,
      );
    }

    final safe = _isReadOnly(executable, arguments, shell) &&
        !_hasMutationFlags(executable, arguments);
    return _SegmentResult(executable, arguments, shell, safe);
  }

  static bool _isReadOnly(
      String executable, List<String> arguments, CommandShell shell) {
    if (shell == CommandShell.powershell ||
        executable.startsWith('[') && executable.contains('::')) {
      final lower = executable.toLowerCase();
      final name = lower.startsWith('[') && lower.contains('::')
          ? lower.substring(0, lower.indexOf('('))
          : lower;
      return _powershellReadOnly.contains(name) ||
          name == '[environment]::getfolderpath';
    }
    if (shell == CommandShell.cmd) return _cmdReadOnly.contains(executable);
    if (!_posixReadOnly.contains(executable)) return false;
    if (executable == 'find') {
      return !arguments.any((a) =>
          const {'-delete', '-exec', '-execdir', '-ok', '-okdir'}.contains(a));
    }
    return true;
  }

  static bool _hasMutationFlags(String executable, List<String> arguments) {
    if (executable == 'sed') {
      return arguments.any((a) =>
          a == '--in-place' ||
          a.startsWith('--in-place=') ||
          RegExp(r'^-[A-Za-z]*i[A-Za-z]*(?:\..+)?$').hasMatch(a));
    }
    if (executable == 'less' || executable == 'more') {
      return arguments.any((a) => a.startsWith('-o') || a.startsWith('-O'));
    }
    if (executable == 'ip') {
      const mutating = {
        'add',
        'append',
        'attach',
        'change',
        'del',
        'delete',
        'detach',
        'exec',
        'flush',
        'prepend',
        'replace',
        'set',
      };
      return arguments.any((a) => mutating.contains(a.toLowerCase()));
    }
    if (executable == 'ss') {
      return arguments.any((a) {
        final lower = a.toLowerCase();
        return lower == '-k' ||
            lower == '--kill' ||
            lower.startsWith('--kill=');
      });
    }
    return false;
  }

  static bool _isInterpreterWithCode(
      String executable, List<String> arguments) {
    const shells = {'bash', 'sh', 'zsh', 'dash', 'fish', 'ksh'};
    const languages = {
      'python',
      'python3',
      'node',
      'perl',
      'ruby',
      'php',
      'lua'
    };
    if (shells.contains(executable)) {
      return arguments.any((a) => const {'-c', '-lc', '-ic'}.contains(a));
    }
    if (languages.contains(executable)) {
      return arguments.isNotEmpty &&
          !(arguments.length == 1 &&
              const {'--version', '-v', '-h'}.contains(arguments.single));
    }
    return false;
  }

  static bool _isPowerShell(String value) {
    final name = _commandName(value);
    return name == 'powershell' ||
        name == 'powershell.exe' ||
        name == 'pwsh' ||
        name == 'pwsh.exe';
  }

  static bool _isCmd(String value) =>
      _commandName(value) == 'cmd' || _commandName(value) == 'cmd.exe';

  static CommandShell _shellFor(String token) {
    if (_isPowerShell(token)) return CommandShell.powershell;
    if (_isCmd(token)) return CommandShell.cmd;
    if (_powershellReadOnly.contains(token.toLowerCase()) ||
        token.startsWith('[') && token.contains('::')) {
      return CommandShell.powershell;
    }
    if (_cmdReadOnly.contains(token.toLowerCase())) return CommandShell.unknown;
    return CommandShell.posix;
  }

  static void detectedPowerShell(
    String executable,
    List<String> arguments,
    Set<CommandEffect> effects,
    List<UnresolvedConstruct> unresolved,
  ) {
    if (arguments.any((a) => a.toLowerCase() == '-encodedcommand')) {
      unresolved.add(const UnresolvedConstruct(
          'encoded_command', 'PowerShell -EncodedCommand 内容未静态解析'));
    }
    if (arguments.any((a) =>
        a.toLowerCase().startsWith('-executionpolicy') ||
        a.toLowerCase() == '-ep')) {
      effects.add(CommandEffect.environmentModification);
    }
    if (arguments.any((a) => a.toLowerCase() == '-file')) {
      unresolved.add(const UnresolvedConstruct(
          'script_file', 'PowerShell -File 脚本内容未静态解析'));
    }
    // Keep the executable parameter explicit: this method describes wrapper effects,
    // not the identity of the command eventually run.
    assert(executable.isNotEmpty);
  }

  static int _powerShellCommandIndex(List<String> arguments) {
    if (arguments.any((a) => a.toLowerCase() == '-encodedcommand')) return -1;
    for (var i = 0; i < arguments.length; i++) {
      final arg = arguments[i];
      if (arg.toLowerCase() == '-file') return -1;
      if (const {'-command', '-c'}.contains(arg.toLowerCase())) {
        if (i + 1 >= arguments.length) return -1;
        var value = arguments[i + 1];
        if (value.isEmpty && i + 2 < arguments.length) {
          final remaining = arguments.skip(i + 2).join(' ');
          if (_stripOuterQuotes(remaining).isNotEmpty) value = remaining;
        }
        return i + 1;
      }
    }
    return -1;
  }

  static bool _isWrapper(String executable) => const {
        'sudo',
        'doas',
        'env',
        'nice',
        'timeout',
        'time',
        'command',
        'builtin',
        'nohup',
        'xargs',
      }.contains(executable);

  static int _wrapperCommandIndex(
    String executable,
    List<String> arguments,
    Set<CommandEffect> effects,
  ) {
    switch (executable) {
      case 'sudo':
      case 'doas':
        effects.add(CommandEffect.privilegeEscalation);
        var i = 0;
        while (i < arguments.length && arguments[i].startsWith('-')) {
          final option = arguments[i++];
          if (const {'-u', '-g', '-h', '-p', '-C', '-T', '-r', '-t', '-U'}
                  .contains(option) &&
              i < arguments.length) {
            i++;
          }
        }
        return i < arguments.length ? i : -1;
      case 'env':
        effects.add(CommandEffect.environmentModification);
        var i = 0;
        while (i < arguments.length &&
            (_isAssignment(arguments[i]) || arguments[i].startsWith('-'))) {
          if (const {'-u', '-C', '-S'}.contains(arguments[i])) i++;
          i++;
        }
        return i < arguments.length ? i : -1;
      case 'nice':
        if (arguments.isNotEmpty &&
            const {'-n', '--adjustment'}.contains(arguments.first)) {
          if (arguments.length < 3) return -1;
          effects.add(CommandEffect.processControl);
          return 2;
        }
        if (arguments.isNotEmpty &&
            RegExp(r'^-\d+$').hasMatch(arguments.first)) {
          effects.add(CommandEffect.processControl);
          return arguments.length > 1 ? 1 : -1;
        }
        effects.add(CommandEffect.processControl);
        return arguments.isNotEmpty ? 0 : -1;
      case 'timeout':
        if (arguments.length < 2) return -1;
        var i = 0;
        while (i < arguments.length && arguments[i].startsWith('-')) {
          final option = arguments[i++];
          if (const {'-s', '-k'}.contains(option)) i++;
        }
        if (i < arguments.length) i++;
        effects.add(CommandEffect.processControl);
        return i < arguments.length ? i : -1;
      case 'time':
      case 'nohup':
        effects.add(CommandEffect.processControl);
        return arguments.isNotEmpty ? 0 : -1;
      case 'command':
      case 'builtin':
        var i = 0;
        while (i < arguments.length && arguments[i].startsWith('-')) i++;
        return i < arguments.length ? i : -1;
      case 'xargs':
        effects.add(CommandEffect.processControl);
        var i = 0;
        while (i < arguments.length && arguments[i].startsWith('-')) {
          final option = arguments[i++];
          if (const {'-I', '-L', '-n', '-P', '-E', '-a'}.contains(option)) i++;
        }
        return i < arguments.length ? i : -1;
      default:
        return -1;
    }
  }

  static List<String> _segments(
      String raw, List<UnresolvedConstruct> unresolved) {
    final out = <String>[];
    final powerShell = _looksPowerShell(raw);
    var start = 0;
    String? quote;
    var escaped = false;
    var pipeline = false;
    for (var i = 0; i < raw.length; i++) {
      final char = raw[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char == '\\' && quote != "'" && !powerShell) {
        escaped = true;
        continue;
      }
      if (powerShell && char == '`' && quote != "'") {
        if (i + 1 >= raw.length) {
          unresolved
              .add(const UnresolvedConstruct('dangling_escape', '行尾转义未闭合'));
          break;
        }
        i++;
        continue;
      }
      if (quote != null) {
        if (char == quote) quote = null;
        continue;
      }
      if (char == "'" || char == '"') {
        quote = char;
        continue;
      }
      if (char == '|' || char == ';') {
        final next = i + 1 < raw.length ? raw[i + 1] : '';
        if ((char == '|' && next == '|') || (char == ';' && next == ';')) {
          i++;
        }
        final value =
            raw.substring(start, i - (char == ';' && next == ';' ? 1 : 0));
        if (value.trim().isNotEmpty) out.add(value.trim());
        start = i + 1;
        if (char == '|') pipeline = true;
      } else if (char == '&' && (i == 0 || raw[i - 1] != '>')) {
        if (i + 1 < raw.length && raw[i + 1] == '&') {
          final value = raw.substring(start, i);
          if (value.trim().isNotEmpty) out.add(value.trim());
          start = ++i + 1;
        } else if (quote == null) {
          final value = raw.substring(start, i);
          if (value.trim().isNotEmpty) out.add(value.trim());
          start = i + 1;
        }
      }
    }
    if (quote != null) {
      unresolved.add(const UnresolvedConstruct('unclosed_quote', '引号未闭合'));
    }
    final tail = raw.substring(start).trim();
    if (tail.isNotEmpty) out.add(tail);
    if (pipeline && out.length > 1) {
      // Effects are attached by parse() after all segment results are known.
    }
    return out;
  }

  static List<String> _tokens(
    String segment,
    List<UnresolvedConstruct> unresolved,
    Set<CommandEffect> effects,
  ) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    final powerShell = _looksPowerShell(segment);
    String? quote;
    var escaped = false;
    var redirectTarget = false;

    void flush() {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
      redirectTarget = false;
    }

    for (var i = 0; i < segment.length; i++) {
      final char = segment[i];
      if (escaped) {
        buffer.write(char);
        escaped = false;
        continue;
      }
      if (powerShell && char == '`' && quote != "'") {
        if (i + 1 >= segment.length) {
          escaped = true;
          continue;
        }
        final next = segment[++i];
        if (next == '\n' || next == '\r') {
          flush();
        } else {
          buffer.write(next);
        }
        continue;
      }
      if (char == '\\' && quote != "'" && !powerShell) {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (char == quote) {
          quote = null;
        } else {
          _inspectExpansion(char, quote, segment, i, unresolved);
          buffer.write(char);
        }
        continue;
      }
      if (char == "'" || char == '"') {
        quote = char;
        continue;
      }
      if (char == '\n' || char == '\r') {
        if (RegExp(r'''<<-?\s*['"]?[A-Za-z_][\w]*''').hasMatch(segment)) {
          unresolved.add(const UnresolvedConstruct(
              'heredoc', 'heredoc 内容未作为 shell AST 静态分析'));
        }
        flush();
        continue;
      }
      if (char == '>' || char == '<') {
        if (char == '<' && i + 1 < segment.length && segment[i + 1] == '(') {
          unresolved.add(
              const UnresolvedConstruct('process_substitution', '进程替换未静态展开'));
          flush();
          i++;
          continue;
        }
        if (char == '<' && i + 1 < segment.length && segment[i + 1] == '<') {
          unresolved.add(const UnresolvedConstruct(
              'heredoc', 'heredoc 内容未作为 shell AST 静态分析'));
          flush();
          i++;
          continue;
        }
        flush();
        if (char == '>') {
          if (i + 1 < segment.length && segment[i + 1] == '>') i++;
          effects.add(CommandEffect.outputRedirect);
        } else if (i > 0 && segment[i - 1] == '&') {
          effects.add(CommandEffect.inputRedirect);
        } else {
          effects.add(CommandEffect.inputRedirect);
        }
        redirectTarget = true;
        continue;
      }
      if (char == '&' &&
          i + 1 < segment.length &&
          segment[i + 1] == '>' &&
          quote == null) {
        continue;
      }
      if (char == '|' ||
          char == ';' ||
          char == '&' ||
          char == ' ' ||
          char == '\t') {
        flush();
        if (char == '|') effects.add(CommandEffect.pipeline);
        continue;
      }
      if (char == '`' && !_looksPowerShell(segment)) {
        unresolved.add(
            const UnresolvedConstruct('command_substitution', '反引号命令替换未静态展开'));
      }
      _inspectExpansion(char, null, segment, i, unresolved);
      if (char == '>' && i + 1 < segment.length && segment[i + 1] == '&') {
        i++;
        continue;
      }
      buffer.write(char);
    }
    if (escaped) {
      unresolved.add(const UnresolvedConstruct('dangling_escape', '行尾转义未闭合'));
    }
    if (quote != null) {
      unresolved.add(const UnresolvedConstruct('unclosed_quote', '引号未闭合'));
    }
    if (redirectTarget && tokens.isEmpty) {
      unresolved.add(const UnresolvedConstruct('empty_redirect', '重定向缺少目标'));
    }
    flush();
    return tokens;
  }

  static void _inspectExpansion(
    String char,
    String? quote,
    String segment,
    int index,
    List<UnresolvedConstruct> unresolved,
  ) {
    if (quote == "'") return;
    if (char == r'$' && index + 1 < segment.length) {
      final next = segment[index + 1];
      if (next == '(' || next == '{' || RegExp(r'[A-Za-z_]').hasMatch(next)) {
        unresolved.add(UnresolvedConstruct(
            next == '(' ? 'command_substitution' : 'variable_expansion',
            'shell 变量或命令替换未静态展开'));
      }
    }
    if (char == '%' &&
        quote == null &&
        index + 2 < segment.length &&
        RegExp(r'%[A-Za-z_][A-Za-z0-9_]*%')
            .hasMatch(segment.substring(index))) {
      unresolved.add(
          const UnresolvedConstruct('cmd_variable_expansion', 'CMD 环境变量未静态展开'));
    }
    if (char == '!' &&
        quote == null &&
        index + 2 < segment.length &&
        RegExp(r'![A-Za-z_][A-Za-z0-9_]*!')
            .hasMatch(segment.substring(index))) {
      unresolved.add(
          const UnresolvedConstruct('cmd_delayed_expansion', 'CMD 延迟变量未静态展开'));
    }
    if (char == '<' &&
        quote == null &&
        index + 1 < segment.length &&
        segment[index + 1] == '(') {
      unresolved
          .add(const UnresolvedConstruct('process_substitution', '进程替换未静态展开'));
    }
  }

  static bool _looksPowerShell(String segment) {
    final match =
        RegExp(r'''^\s*(?:"([^"]+)"|'([^']+)'|([^\s]+))''').firstMatch(segment);
    final first = (match?.group(1) ?? match?.group(2) ?? match?.group(3) ?? '')
        .toLowerCase();
    return _isPowerShell(first) ||
        _powershellReadOnly.contains(first) ||
        first.startsWith('[') && first.contains('::');
  }

  static String _commandName(String token) {
    var value = token.replaceAll(r'\', '/');
    final slash = value.lastIndexOf('/');
    if (slash >= 0) value = value.substring(slash + 1);
    return value.replaceAll('"', '').replaceAll("'", '').toLowerCase();
  }

  static bool _isAssignment(String token) =>
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(token);

  static String _stripOuterQuotes(String value) {
    var result = value.trim();
    if (result.length >= 2 &&
        ((result.startsWith('"') && result.endsWith('"')) ||
            (result.startsWith("'") && result.endsWith("'")))) {
      result = result.substring(1, result.length - 1);
    }
    return result;
  }
}

class _SegmentResult {
  final String? executable;
  final List<String> arguments;
  final CommandShell shell;
  final bool safe;

  const _SegmentResult(this.executable, this.arguments, this.shell, this.safe);
}
