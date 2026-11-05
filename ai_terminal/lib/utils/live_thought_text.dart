/// 流式过程中从 ReAct 原文里取出「当前这一步的思考正文」。
///
/// 模型把 `思考: …` 当正文一起吐出来，协议行（动作/命令/选项…）随后跟上；
/// 直接把原文渲染到界面会把协议当正文展示，所以取最后一段思考并截到下一个
/// 协议行为止。超长只保留尾部：流式展示关心的是"正在想什么"。
String extractLiveThought(String raw, {int maxChars = 1200}) {
  final matches = RegExp(r'思考[:：]').allMatches(raw);
  var text = matches.isEmpty ? raw : raw.substring(matches.last.end);
  final cut = RegExp(r'\n\s*(计划|动作|命令|选项|工具|参数|回答)[:：]').firstMatch(text);
  if (cut != null) text = text.substring(0, cut.start);
  text = text.trim();
  if (text.length > maxChars) {
    text = text.substring(text.length - maxChars);
  }
  return text;
}
