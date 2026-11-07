/// 流式过程中从 ReAct 原文里取出「当前这一步的思考正文」。
///
/// 模型把 `思考: …` 当正文一起吐出来，协议行（动作/命令/选项…）随后跟上；
/// 直接把原文渲染到界面会把协议当正文展示，所以取最后一段思考并截到下一个
/// 协议行为止。超长只保留尾部：流式展示关心的是"正在想什么"。
///
/// 性能：流式期间每 120ms 调用一次。RegExp 提升为 static 复用；优先只扫
/// 尾部窗口——「最后一个 思考:」通常就在尾部（当前步）。窗口内没有标记时
/// 回退全量扫描，保证与原版语义完全一致。
final RegExp _thoughtMarker = RegExp(r'思考[:：]');
final RegExp _protocolLine = RegExp(r'\n\s*(计划|动作|命令|选项|工具|参数|回答)[:：]');

/// 尾部扫描窗口：当前步的思考远超这个长度时，更早的标记不影响展示
/// （展示本来就只保留最后 maxChars 个字符）。
const int _scanWindow = 4096;

String extractLiveThought(String raw, {int maxChars = 1200}) {
  // 优先只扫尾部窗口（常见情况：当前步的「思考:」就在尾部）。
  // 窗口内没有标记时必须回退全量扫描：最后一个标记可能在窗口外，
  // 其后跟着长回答/长代码（如「思考: …\n回答: <长文>」），若直接用窗口
  // 文本会把回答尾部误显示为思考，且丢掉协议行截断。
  final window = raw.length > _scanWindow
      ? raw.substring(raw.length - _scanWindow)
      : raw;
  var matches = _thoughtMarker.allMatches(window);
  var source = window;
  if (matches.isEmpty && !identical(source, raw)) {
    source = raw;
    matches = _thoughtMarker.allMatches(raw);
  }
  var text = matches.isEmpty ? source : source.substring(matches.last.end);
  final cut = _protocolLine.firstMatch(text);
  if (cut != null) text = text.substring(0, cut.start);
  text = text.trim();
  if (text.length > maxChars) {
    text = text.substring(text.length - maxChars);
  }
  return text;
}