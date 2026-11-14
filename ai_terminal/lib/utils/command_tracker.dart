/// 终端输入的命令捕获（命令历史 UI 的数据源）。
///
/// 为什么不直接记按键：密码提示下 shell 关掉回显，用户敲的密码同样是按键。
/// 历史面板里出现 `hunter2` 等于把最敏感的东西抄进一个明文列表 —— 这正是本项目
/// 对会话日志（§5 脱敏）禁止的事。而按键序列本身也靠不住：方向键会送出
/// `ESC [ A` 这类含可打印字符的转义序列，↑ 调出来的历史更不在按键里。
///
/// 所以捕获点的选择是：**回车瞬间读屏幕上的当前输入行**，并叠三道闸门：
///
/// 1. **必须带提示符**：`stripPromptPrefix` 要真的剥掉一段前缀才算「用户在敲命令」。
///    过滤掉 vim/less 这类全屏程序里恰好按下的回车（那行是文件内容，不是命令），
///    也过滤掉 `[sudo] password for u:` —— 它不以提示符开头，剥完全行仍在。
/// 2. **剥完必须有内容**：密码提示下用户敲的字符没有回显，屏幕上提示符后面
///    是空的 → 什么都不记。这条不依赖提示语正则，中文/法文 locale 一样成立。
/// 3. **必须像命令**：沿用 `looksLikeCommand`（单行、首 token 像程序名），
///    与右键菜单「这条像命令吗」同一套口径，避免两处判定漂移。
///
/// 另有一个输出侧的密码提示锁（`[sudo]`/`Password:`/`passphrase`/`密码`）作为纵深：
/// 命中期间丢弃输入。最坏情况是漏记一条历史，绝不会多记一个密码。
///
/// 已知降级：提示符正则认不出的 shell（如 cmd.exe 的 `C:\>` 裸盘符行）不记历史。
/// 历史只是便利功能，shell 自身的 ↑ 不受影响，宁缺毋滥。
library;

import 'terminal_text_actions.dart' show looksLikeCommand, stripPromptPrefix;

/// 捕获一条命令的回调（页面据此落库）
typedef CommandCaptured = void Function(String command);

class CommandTracker {
  CommandTracker({this.onCommand});

  final CommandCaptured? onCommand;

  /// 输出尾部的密码/口令提示（纵深防御的第二道闸门）
  bool _awaitingSecret = false;

  /// 上一条已记录的命令：连续重复不再记（`ls` 连敲五次留一条）
  String _lastRecorded = '';

  /// `[sudo]` 前缀在所有 locale 下保留（`[sudo] cjm 的密码：`），且必须卡在
  /// 缓冲尾部 —— 正文里的 `[sudo]` 不算（R8：不用裸子串判定）。
  static final RegExp _sudoPromptAtEnd =
      RegExp(r'\[sudo\][^\r\n]*[:：][ \t]*$');

  /// ssh / mysql / keychain 之类提示，含中英文。同样只看尾部。
  static final RegExp _secretPromptAtEnd = RegExp(
    r'(?:password|passphrase|密码|口令)[^\r\n]*[:：][ \t]*$',
    caseSensitive: false,
  );

  /// ANSI 序列剥离（判定提示语时不能被颜色码干扰）
  static final RegExp _ansiStrip = RegExp(
    r'\x1B\[[\x30-\x3F]*[\x20-\x2F]*[\x40-\x7E]'
    r'|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)'
    r'|\x1B[@-Z\\-_]',
  );

  static const int _tailCap = 2048;
  final StringBuffer _output = StringBuffer();

  String get _tail {
    final s = _output.toString();
    return s.length <= _tailCap ? s : s.substring(s.length - _tailCap);
  }

  /// 终端输出（与显示/会话日志同一份解码文本）
  void onOutput(String data) {
    _output.write(data);
    if (_output.length > _tailCap * 2) {
      final s = _output.toString();
      _output
        ..clear()
        ..write(s.substring(s.length - _tailCap));
    }
    final tail = _tail.replaceAll(_ansiStrip, '');
    _awaitingSecret =
        _sudoPromptAtEnd.hasMatch(tail) || _secretPromptAtEnd.hasMatch(tail);
  }

  /// 用户键盘输入。[currentInputLine] 惰性提供**当前屏幕输入行**的文本
  /// （页面从 xterm buffer 的光标行读出）；只在回车时才被调用。
  ///
  /// 回车时缓冲区仍是命令行的原样：输出要等 shell 处理完才到，
  /// 所以这一刻读到的就是用户看到的那一行。
  void onInput(String data, {required String Function() currentInputLine}) {
    if (!_hasSubmit(data)) return;
    if (_awaitingSecret) {
      // 应答完密码，下一次输入回到正常捕获
      _awaitingSecret = false;
      return;
    }
    final command = extract(currentInputLine());
    if (command == null || command == _lastRecorded) return;
    _lastRecorded = command;
    onCommand?.call(command);
  }

  static bool _hasSubmit(String data) {
    for (final rune in data.runes) {
      if (rune == 0x0d || rune == 0x0a) return true;
    }
    return false;
  }

  /// 重连/清屏后重置，避免带着上一条连接的提示语锁继续判定
  void reset() {
    _output.clear();
    _awaitingSecret = false;
    _lastRecorded = '';
  }

  /// 从一行屏幕文本里取出命令；不满足任一闸门返回 null。纯函数，供单测直调。
  static String? extract(String screenLine) {
    if (screenLine.trim().isEmpty) return null;
    final stripped = stripPromptPrefix(screenLine);
    // 闸门 1：没剥掉任何东西 → 这行不是「提示符 + 命令」
    if (stripped.length == screenLine.length) return null;
    final command = stripped.trim();
    // 闸门 2：提示符后面什么都没有（关回显的密码输入）
    if (command.isEmpty) return null;
    // 闸门 3：像命令吗
    if (!looksLikeCommand(command)) return null;
    return command;
  }
}
