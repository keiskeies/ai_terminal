// tool_args.ts - 1:1 port of Dart ai_terminal/lib/utils/tool_args_parser.dart
//
// Parses ReAct "参数:" multi-line key:value text into Record<string, unknown>
// and exposes the ONLY sanctioned typed accessors (AGENTS.md R9): tool
// implementations must use getString/getStringList/getBool/getInt here instead
// of doing their own is List / is String coercion on a raw map.
//
// Rules (must stay in sync with Dart):
//  - indent 2-space or tab
//  - value = whole rest-of-line after the FIRST colon (trimmed); paths w/ spaces ok
//  - a non-empty line with NO colon => block unparseable => return null
//    (model wrote the value across lines; silently skipping would drop content)
//  - "true"/"false" -> boolean; pure integer -> int; hostIds/exclude comma -> List
//  - JSON ({...}) is rejected -> null (forces multi-line key:value)

export class ToolArgException extends Error {
  constructor(public readonly key: string) {
    // 缺少必填参数: <key>
    super("\u7F3A\u5C11\u5FC5\u586B\u53C2\u6570: " + key);
    this.name = "ToolArgException";
  }
}

export class ToolArgsParser {
  static parse(argsText: string): Record<string, unknown> | null {
    const trimmed = argsText.trim();
    if (trimmed === "") return null;
    if (trimmed.startsWith("{")) return null; // reject JSON, force multi-line
    const result: Record<string, unknown> = {};
    const lines = trimmed.split("\n");
    let hasAny = false;
    for (const rawLine of lines) {
      if (rawLine.trim() === "") continue;
      const line = rawLine.replace(/^\s*/, "");
      const colonIdx = line.indexOf(":");
      if (colonIdx < 0) return null; // no-colon non-empty line = cross-line value
      const key = line.substring(0, colonIdx).trim();
      const rawValue = line.substring(colonIdx + 1).trim();
      if (key === "") continue;
      result[key] = ToolArgsParser._convertValue(key, rawValue);
      hasAny = true;
    }
    return hasAny ? result : null;
  }

  static _convertValue(key: string, rawValue: string): unknown {
    if (rawValue === "true") return true;
    if (rawValue === "false") return false;
    if (/^-?\d+$/.test(rawValue)) return parseInt(rawValue, 10);
    const listKeys = new Set(["hostIds", "exclude"]);
    if (listKeys.has(key) && rawValue.includes(",")) {
      return rawValue.split(",").map((s) => s.trim()).filter((s) => s.length > 0);
    }
    return rawValue;
  }

  // ── typed helpers: the ONLY sanctioned accessors (R9) ──
  static getString(args: Record<string, unknown>, key: string, defaultValue = ""): string {
    const v = args[key];
    if (v === null || v === undefined) return defaultValue;
    if (typeof v === "string") return v;
    if (Array.isArray(v)) return (v as unknown[]).join(",");
    return String(v);
  }

  static getStringList(args: Record<string, unknown>, key: string, defaultValue: string[] = []): string[] {
    const v = args[key];
    if (v === null || v === undefined) return defaultValue;
    if (Array.isArray(v)) return v.map((e) => String(e)).filter((s) => s.length > 0);
    if (typeof v === "string") return ToolArgsParser._splitListText(v);
    const s = String(v);
    return s === "" ? defaultValue : [s];
  }

  static _splitListText(value: string): string[] {
    let text = value.trim();
    if (text.startsWith("[") && text.endsWith("]") && text.length >= 2) {
      text = text.substring(1, text.length - 1);
    }
    // support Chinese comma as well
    return text.split(/[,\uFF0C]/).map((s) => s.trim()).filter((s) => s.length > 0);
  }

  static getBool(args: Record<string, unknown>, key: string, defaultValue = false): boolean {
    const v = args[key];
    if (v === null || v === undefined) return defaultValue;
    if (typeof v === "boolean") return v;
    if (typeof v === "string") return v.toLowerCase() === "true";
    return defaultValue;
  }

  static getInt(args: Record<string, unknown>, key: string, defaultValue = 0): number {
    const v = args[key];
    if (v === null || v === undefined) return defaultValue;
    if (typeof v === "number") return Math.trunc(v);
    if (typeof v === "string") {
      const n = parseInt(v, 10);
      return Number.isNaN(n) ? defaultValue : n;
    }
    return defaultValue;
  }
}

/**
 * Typed accessor wrapper over the parsed args map (1:1 ToolArgs from Dart).
 * Tool implementations MUST use this (or the static ToolArgsParser helpers),
 * never a raw map access, so List/String/bool/int coercion stays in one place.
 */
export class ToolArgs {
  /** Shared empty instance. */
  static readonly EMPTY: ToolArgs = new ToolArgs({});
  /** Convenience alias for new ToolArgs(map). */
  static wrap(raw: Record<string, unknown>): ToolArgs { return new ToolArgs(raw); }
  /** Wrap an already-parsed args map. */
  constructor(private readonly raw: Record<string, unknown>) {}

  /** Parse free-text ReAct param block; null => no usable args. */
  static parse(text: string): ToolArgs | null {
    const m = ToolArgsParser.parse(text);
    return m ? new ToolArgs(m) : null;
  }

  get isEmpty(): boolean { return Object.keys(this.raw).length === 0; }
  get keys(): string[] { return Object.keys(this.raw); }
  /** Unmodifiable view for audit/logs; do NOT use to read business params. */
  get asMap(): Record<string, unknown> { return new Map(Object.entries(this.raw)) as any; }

  has(key: string): boolean {
    const v = this.raw[key];
    if (v === null || v === undefined) return false;
    if (typeof v === "string") return v.length > 0;
    if (Array.isArray(v)) return v.length > 0;
    return true;
  }

  containsKey(key: string): boolean { return key in this.raw; }

  getString(key: string, defaultValue = ""): string {
    return ToolArgsParser.getString(this.raw, key, defaultValue);
  }

  /** Required string: throws ToolArgException if missing/blank. */
  requireString(key: string): string {
    const v = this.getString(key).trim();
    if (v === "") throw new ToolArgException(key);
    return v;
  }

  /** First non-blank string among candidate keys (e.g. remote / remoteDir). */
  firstOf(keyNames: string[], defaultValue = ""): string {
    for (const k of keyNames) {
      const v = this.getString(k).trim();
      if (v !== "") return v;
    }
    return defaultValue;
  }

  getStringList(key: string, defaultValue: string[] = []): string[] {
    return ToolArgsParser.getStringList(this.raw, key, defaultValue);
  }

  getBool(key: string, defaultValue = false): boolean {
    return ToolArgsParser.getBool(this.raw, key, defaultValue);
  }

  getInt(key: string, defaultValue = 0): number {
    return ToolArgsParser.getInt(this.raw, key, defaultValue);
  }

  /** Log/observation summary: truncates values, keeps full content out of logs. */
  describe(maxValueChars = 80): string {
    const entries = Object.entries(this.raw);
    if (entries.length === 0) return "(no args)";
    return entries.map(([k, v]) => {
      let val = Array.isArray(v) ? (v as unknown[]).join(",") : String(v);
      if (val.length > maxValueChars) val = val.substring(0, maxValueChars) + "...(" + val.length + ")";
      return k + "=" + val;
    }).join(", ");
  }
}

