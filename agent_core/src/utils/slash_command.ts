// utils/slash_command.ts - r207 port of utils/slash_command.dart (120 lines).
//
// 斜杠命令解析：把输入拆成「命令名 + 原样参数」。
//
// 只承认命中已知命令名的输入为命令，这一点是硬要求：本输入框的目标文本经常
// 以远程路径开头（`/etc/nginx 目录权限`），若把首个 `/` 开头一律当命令，
// 用户就没法让 agent 处理绝对路径了。
//
// The only Dart import was agent_permission_mode.dart; the Node port reuses the
// rpc/schema PermissionMode wire ids (readOnly/ask/auto/fullAuto = the Dart .id
// values verbatim), so shouldRestorePermissionMode needs no new model type.

import {PermissionMode} from "../rpc/schema.js";

/// 解析结果
export interface ParsedSlashCommand {
  /// 已小写化的命令名，如 `/goal`
  name: string;
  /// 命令名之后剩余的全部原文（去掉分隔空格，保留内部与原始大小写）。
  /// 没有参数时为 null。
  rest: string | null;
}

export const hasRest = (c: ParsedSlashCommand): boolean => c.rest !== null && c.rest.length > 0;

/// [knownNames] 为已注册命令名（带前导 `/`，大小写不敏感匹配）。
/// 不是命令时返回 null，调用方按普通文本发送。
export function parseSlashCommand(
  input: string,
  knownNames: Iterable<string>,
): ParsedSlashCommand | null {
  const trimmed = input.trim();
  if (!trimmed.startsWith("/")) return null;

  const firstSpace = trimmed.indexOf(" ");
  const head = firstSpace < 0 ? trimmed : trimmed.slice(0, firstSpace);
  const normalised = head.toLowerCase();

  for (const name of knownNames) {
    if (name.toLowerCase() !== normalised) continue;
    if (firstSpace < 0) return {name: normalised, rest: null};
    // 参数只去掉命令名与正文之间的空白，正文本身一律原样保留：
    // 目标描述里的大小写、空格、标点都是用户意图
    const rest = trimmed.slice(firstSpace + 1).replace(/^\s+/, "");
    return {name: normalised, rest: rest.length === 0 ? null : rest};
  }
  return null;
}

/// `/model` 的名称匹配：先精确（忽略大小写），再子串。
///
/// 返回命中的原始名称列表；长度 > 1 表示歧义，由调用方列候选让用户选，
/// **不自动挑一个**——猜错等于把任务发到另一个计费与能力都不同的后端。
export function matchModelNames(names: Iterable<string>, wanted: string): string[] {
  const needle = wanted.trim().toLowerCase();
  if (needle.length === 0) return [];
  const all = [...names];
  const exact = all.filter((n) => n.toLowerCase() === needle);
  if (exact.length > 0) return exact;
  return all.filter((n) => n.toLowerCase().includes(needle));
}

/// `/plan` 结束后是否要把权限档位拨回去。
///
/// 规则是"恢复原值"，不是"恢复询问"：原本是自动/全自动的用户，跑一次 `/plan`
/// 不该被顺手改档；原本就是只读的也不用重复设置。只有用户没有手动动过
/// （当前仍是 /plan 临时设置的只读）时才还原。
export function shouldRestorePermissionMode(before: PermissionMode, now: PermissionMode): boolean {
  return now === "readOnly" && before !== "readOnly";
}

export const kGoalSubCommands: ReadonlySet<string> = new Set([
  "pause",
  "resume",
  "edit",
  "done",
  "clear",
]);

/// 一条 `/goal` 的解析结果。
export interface GoalCommand {
  /// 命中的子命令（已小写）；null 表示整句都是目标文本
  sub: string | null;
  /// 子命令之后的内容；sub 为 null 时即整句目标（空串表示裸 `/goal`）
  objective: string;
}

/// 子命令与目标文本的消歧。
///
/// 规则：
/// - `edit` 是唯一带参数的子命令，后面整句是新目标；
/// - `pause` / `resume` / `done` / `clear` 不接受参数，**必须独占整句**才算指令；
///   后面还有正文就退回成目标文本——`/goal pause the server 卡住了` 是用户在
///   描述问题，不是下达指令。宁可把一句指令当成目标建出来（横幅看得见、
///   `/goal clear` 可撤销），也不该把用户输入的目标悄悄吞掉。
export function parseGoalCommand(rest: string | null | undefined): GoalCommand {
  const text = (rest ?? "").trim();
  if (text.length === 0) {
    return {sub: null, objective: ""};
  }
  const firstSpace = text.indexOf(" ");
  const head = firstSpace < 0 ? text : text.slice(0, firstSpace);
  const lower = head.toLowerCase();
  if (!kGoalSubCommands.has(lower)) {
    return {sub: null, objective: text};
  }
  const tail = firstSpace < 0 ? "" : text.slice(firstSpace + 1).trim();
  if (lower === "edit") {
    return {sub: "edit", objective: tail};
  }
  if (tail.length > 0) {
    return {sub: null, objective: text};
  }
  return {sub: lower, objective: ""};
}
