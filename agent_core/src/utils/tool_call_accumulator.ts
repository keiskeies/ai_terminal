// ToolCallAccumulator - port of Dart tool_call_accumulator.dart 1-169.
//
// Accumulates OpenAI streaming tool_calls: the first chunk carries id + name,
// subsequent chunks carry argument fragments. finalize() returns complete calls,
// toReActText() formats them for the ReAct parser.

export interface ToolCall {
  id: string;
  name: string;
  arguments: string;
}

export class ToolCallAccumulator {
  // Dart 19: index -> {id, name, arguments}
  private _partials = new Map<number, {id?: string; name?: string; arguments: string}>();

  // Dart 22-41: process delta.tool_calls (each chunk's delta array)
  addDelta(toolCallsDelta: unknown[] | null | undefined): void {
    if (toolCallsDelta === null || toolCallsDelta === undefined) return;
    for (const raw of toolCallsDelta) {
      if (typeof raw !== "object" || raw === null) continue;
      const r = raw as Record<string, unknown>;
      const index = r["index"] as number | undefined;
      if (index === undefined) continue;
      let partial = this._partials.get(index);
      if (!partial) { partial = {arguments: ""}; this._partials.set(index, partial); }
      const id = r["id"] as string | undefined;
      if (id !== undefined && id.length > 0) partial.id = id;
      const fn = r["function"] as Record<string, unknown> | undefined;
      if (fn !== undefined) {
        const name = fn["name"] as string | undefined;
        if (name !== undefined && name.length > 0) partial.name = name;
        const args = fn["arguments"] as string | undefined;
        if (args !== undefined && args.length > 0) partial.arguments += args;
      }
    }
  }

  // Dart 45-61: finalize - return all accumulated tool_calls, clear _partials
  finalize(): ToolCall[] {
    const result: ToolCall[] = [];
    const indices = Array.from(this._partials.keys()).sort((a, b) => a - b);
    for (const idx of indices) {
      const p = this._partials.get(idx);
      if (!p || p.name === undefined) continue;
      result.push({
        id: p.id ?? ("call_" + idx),
        name: p.name,
        arguments: ToolCallAccumulator._repairArguments(p.arguments),
      });
    }
    // Dart 57-58: P2-6 fix - clear to prevent double-delivery
    this._partials.clear();
    return result;
  }

  // Dart 74-93: toReActText - convert tool_calls to ReAct text format
  static toReActText(calls: ToolCall[]): string {
    const lines: string[] = [String.fromCharCode(10)]; // Dart 77: leading newline
    for (let i = 0; i < calls.length; i++) {
      const c = calls[i];
      if (i > 0) lines.push(String.fromCharCode(10)); // Dart 80: blank line between calls
      lines.push("\u52a8\u4f5c: tool");
      lines.push("\u5de5\u5177: " + c.name);
      const argsText = ToolCallAccumulator._jsonToKeyValue(c.arguments);
      if (argsText.length === 0) {
        lines.push("\u53c2\u6570:");
      } else {
        lines.push("\u53c2\u6570:");
        lines.push(argsText);
      }
    }
    return lines.join("").replace(/\s+$/, ""); // Dart 92: trimRight
  }

  // Dart 99-120: JSON arguments to multi-line key:value
  private static _jsonToKeyValue(jsonArgs: string): string {
    const trimmed = jsonArgs.trim();
    if (trimmed.length === 0 || trimmed === "{}") return "";
    try {
      const decoded = JSON.parse(trimmed);
      if (typeof decoded !== "object" || decoded === null || Array.isArray(decoded)) return "";
      const m = decoded as Record<string, unknown>;
      const lines: string[] = [];
      for (const [key, value] of Object.entries(m)) {
        if (Array.isArray(value)) {
          lines.push("  " + key + ": " + value.join(","));
        } else {
          lines.push("  " + key + ": " + String(value));
        }
      }
      return lines.join(String.fromCharCode(10));
    } catch {
      return "";
    }
  }

  // Dart 124-144: repair malformed JSON (append missing closing braces)
  private static _repairArguments(args: string): string {
    if (args.length === 0) return "{}";
    try {
      JSON.parse(args);
      return args;
    } catch {
      const openCount = (args.match(/\{/g) || []).length;
      const closeCount = (args.match(/\}/g) || []).length;
      if (openCount > closeCount) {
        const repaired = args + "}".repeat(openCount - closeCount);
        try {
          JSON.parse(repaired);
          return repaired;
        } catch {
          // repair failed, return original (ToolArgsParser handles multi-line format)
        }
      }
      return args;
    }
  }

  // Dart 146
  get hasPendingCalls(): boolean { return this._partials.size > 0; }
}
