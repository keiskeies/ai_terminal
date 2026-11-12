// src/utils/choice_request_detector.ts - 1:1 port of
// ai_terminal/lib/utils/choice_request_detector.dart (132 lines).
// 从 finish / 回答正文里识别「让用户在若干方案中选择」的请求。
//
// ReAct 协议要求提问走 `动作: ask` + `选项:`，但部分模型会把
// “请回复选择 A 还是 B”写进 finish 正文：UI 没有按钮，任务却在用户
// 做决定前收尾。这里做保守兜底 —— 必须同时命中「明确的选择请求」和
// 「可提取的选项」才转换，普通总结里的“建议: 可以考虑 A 或 B”不会误伤。

export class ChoiceRequest {
  constructor(
    public readonly question: string,
    public readonly options: readonly string[],
  ) {}
}

export class ChoiceRequestDetector {
  /// 只看正文末尾：选择请求几乎总在回答收尾处，避免扫到历史里的示例。
  private static readonly tailLines = 25;

  /// 询问窗口：选项通常紧挨着提问行，最多向前回看 6 行。
  private static readonly optionLookback = 6;

  private static readonly maxQuestionChars = 600;
  private static readonly maxOptionDescChars = 60;

  /// 明确的选择请求。单独的“请确认”不算 —— 那多半是命令确认，不是选项。
  private static readonly CUE = new RegExp(
    "请\\s*(?:你\\s*)?(?:回复|选择|选一个|选个|挑选|告诉|做出选择|确认选择)" +
    "|需要你(?:来)?(?:选择|决定|确认)" +
    "|(?:回复|选择)\\s*(?:选项|[A-Za-z0-9一二三四五六])" +
    "|(?:哪一?个|哪一种|哪套|哪个)(?:方案|方式|做法|版本)" +
    "|(?:选|用)\\s*[A-Za-z]\\s*(?:还是|或|/)",
  );

  /// “请回复选择 A 还是 B”这类只有字母、没有描述的写法。
  private static readonly binaryLetters =
    /(?:选择|回复|选)\s*([A-Za-z0-9一二三四五六])\s*(?:还是|或|\/|、)\s*([A-Za-z0-9一二三四五六])/;

  private static readonly letterOption =
    /^\s*(?:[-*•·]\s*)?(?:方案\s*)?([A-Za-z])\s*[.、:：)）]\s*(\S.{0,59})$/;

  private static readonly numberedOption =
    /^\s*(?:[-*•·]\s*)?(?:方案\s*)?([1-6一二三四五六])\s*[.、:：)）]\s*(\S.{0,59})$/;

  private static readonly trailingPunct = /[。；;，,\s]+$/;

  /// 返回 null 表示不是明确的选择请求，调用方应照常 finish。
  static detect(text: string): ChoiceRequest | null {
    const trimmed = text.trim();
    if (trimmed === "") return null;

    const allLines = trimmed.split(/\r?\n/);
    const start =
      allLines.length > ChoiceRequestDetector.tailLines
        ? allLines.length - ChoiceRequestDetector.tailLines
        : 0;
    const lines = allLines.slice(start);

    // 跳过 ``` 围栏里的内容：示范格式的正文不能被当成真实提问
    const inCode: boolean[] = new Array(lines.length).fill(false);
    let fenced = false;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].trim().startsWith("```")) {
        inCode[i] = true;
        fenced = !fenced;
      } else {
        inCode[i] = fenced;
      }
    }

    let cueIndex = -1;
    for (let i = lines.length - 1; i >= 0; i--) {
      if (inCode[i]) continue;
      if (ChoiceRequestDetector.CUE.test(lines[i])) {
        cueIndex = i;
        break;
      }
    }
    if (cueIndex < 0) return null;

    const windowStart =
      cueIndex > ChoiceRequestDetector.optionLookback
        ? cueIndex - ChoiceRequestDetector.optionLookback
        : 0;
    const options: string[] = [];
    const optionLines = new Set<number>();
    const seen = new Set<string>();
    const collect = (pattern: RegExp): void => {
      for (let i = windowStart; i < lines.length; i++) {
        if (inCode[i] || optionLines.has(i)) continue;
        const m = pattern.exec(lines[i]);
        if (m === null) continue;
        const label = (m[1] as string).toUpperCase();
        const desc = (m[2] as string).trim().replace(ChoiceRequestDetector.trailingPunct, "");
        if (desc === "" || seen.has(label)) continue;
        seen.add(label);
        const clipped =
          desc.length > ChoiceRequestDetector.maxOptionDescChars
            ? desc.substring(0, ChoiceRequestDetector.maxOptionDescChars) + "…"
            : desc;
        options.push(label + ". " + clipped);
        optionLines.add(i);
      }
    };

    collect(ChoiceRequestDetector.letterOption);
    if (options.length < 2) collect(ChoiceRequestDetector.numberedOption);

    if (options.length < 2) {
      options.length = 0;
      optionLines.clear();
      const binary = ChoiceRequestDetector.binaryLetters.exec(lines[cueIndex] as string);
      if (binary !== null) {
        options.push("方案 " + (binary[1] as string).toUpperCase());
        options.push("方案 " + (binary[2] as string).toUpperCase());
      }
    }

    if (options.length < 2) return null;

    const questionLines: string[] = [];
    const questionStart = cueIndex > 4 ? cueIndex - 4 : 0;
    for (let i = questionStart; i < lines.length; i++) {
      if (optionLines.has(i) || inCode[i]) continue;
      const line = (lines[i] as string).trim();
      if (line !== "") questionLines.push(line);
    }
    let question = questionLines.join("\n").trim();
    if (question === "") question = (lines[cueIndex] as string).trim();
    if (question.length > ChoiceRequestDetector.maxQuestionChars) {
      question =
        "…" + question.substring(question.length - ChoiceRequestDetector.maxQuestionChars);
    }

    return new ChoiceRequest(question, Object.freeze([...options]));
  }
}
