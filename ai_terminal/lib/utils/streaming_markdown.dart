// 流式 Markdown 增量渲染的纯逻辑辅助函数。
//
// 流式文本每 120ms 增长一次；全量重拆代码块 + 重解析 Markdown 是 O(n²)。
// 增量渲染把文本切成「稳定前缀 + 活跃尾部」：前缀按段落/代码块拆成独立
// 缓存块（文本不再变化，缓存必命中），只有尾部每次 flush 重解析。

/// 找最后一个「代码块外的空行」之后的位置作为稳定前缀终点。
///
/// 返回 -1 表示没有可用边界（无空行、空行都在代码块内、或边界恰在文末）。
/// 代码围栏内的空行不是段落边界，不能在那里切，否则会把未闭合的代码块撕开。
int stableParagraphCut(String text) {
  var inCode = false;
  var lastCut = -1;
  var pos = 0;
  for (final line in text.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      inCode = !inCode;
    } else if (!inCode && line.trim().isEmpty) {
      lastCut = pos + line.length + 1;
    }
    pos += line.length + 1;
  }
  if (lastCut <= 0 || lastCut >= text.length) return -1;
  return lastCut;
}

/// 文本若存在未闭合的代码围栏，返回（围栏前文本, 围栏内代码）；否则 null。
///
/// 流式期间代码块经常处于"已开围栏、未闭围栏"状态；把这截内容直接按纯
/// 代码块渲染，避免增长中的代码被当 Markdown 全文反复重解析。
/// 返回的代码不含开围栏那一行（含语言标识）。
(String, String)? unclosedFenceSplit(String text) {
  final lines = text.split('\n');
  var fenceStart = -1;
  var inCode = false;
  var pos = 0;
  for (final line in lines) {
    if (line.trimLeft().startsWith('```')) {
      if (!inCode) {
        fenceStart = pos;
        inCode = true;
      } else {
        inCode = false;
        fenceStart = -1;
      }
    }
    pos += line.length + 1;
  }
  if (!inCode || fenceStart < 0) return null;
  final before = text.substring(0, fenceStart);
  var code = text.substring(fenceStart);
  final nl = code.indexOf('\n');
  code = nl < 0 ? '' : code.substring(nl + 1);
  return (before, code);
}