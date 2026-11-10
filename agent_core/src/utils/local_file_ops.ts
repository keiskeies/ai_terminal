// local_file_ops.ts - 1:1 port of Dart ai_terminal/lib/utils/local_file_ops.dart.
// Shared local-file primitives used by the local_* write/patch tools and the
// audit/record service. Backup + escape semantics live in exactly ONE place so
// the write path and the patch path cannot drift (AGENTS.md R8-3 "double-clean").
// Node note: policy gating lives at the TOOL layer - tools/builtin.ts calls
// resolveLocalPath -> LocalFilePolicy.decide() before touching these helpers, which is
// where Dart gates it too (LocalFileTool._resolve). The primitives here stay un-gated on
// purpose: platform.ts and the restore paths feed them already-decided, post-realpath
// paths, and a second gate in here would be a double check (AGENTS.md R8-3 "clean once,
// at one layer"). Callers that obtain a path from the AI must gate it themselves.
// and does NOT gate I/O on an allowlist. The I/O primitives are ported verbatim.

import {
  readFileSync, writeFileSync, copyFileSync, mkdirSync, statSync, existsSync,
  readdirSync, rmSync, type Stats,
} from "fs";
import { dirname, join, normalize, sep } from "path";
import { Buffer } from "buffer";

export const TRASH_DIR_NAME = ".ai_terminal_trash";

// Decode the escape sequences in a single-line argument: \n \r \t \\ .
// Unknown escapes are kept verbatim. Equivalent to the Dart char-walk.
export function decodeEscapedText(text: string): string {
  return text.replace(/\\(n|r|t|\\)/g, (m, g: string) => {
    if (g === "n") return "\n";
    if (g === "r") return "\r";
    if (g === "t") return "\t";
    if (g === "\\") return "\\";
    return m; // unknown escape kept verbatim
  });
}

export interface DecodedContent { bytes: Buffer; error?: string; }

// When both are given, base64 wins (the caller meant byte-faithful).
export function decodeContent(plain: string, b64: string): DecodedContent {
  if (b64.length > 0) {
    try {
      const cleaned = b64.replace(/\s+/g, "");
      if (!/^[A-Za-z0-9+/=]+$/.test(cleaned) || cleaned.length % 4 !== 0) {
        throw new Error("invalid base64");
      }
      return { bytes: Buffer.from(cleaned, "base64") };
    } catch (e: any) {
      const em = e && e.message ? e.message : String(e);
      return { bytes: Buffer.alloc(0), error: "base64 \u89E3\u7801\u5931\u8D25: " + em };
    }
  }
  return { bytes: Buffer.from(plain, "utf-8") };
}

function microSinceEpoch(): number {
  const ms = Date.now();
  const frac = Math.floor((performance.now() % 1) * 1000);
  return ms * 1000 + frac;
}

export function backupLocalFile(path: string): string {
  const backupPath = path + ".bak." + microSinceEpoch();
  copyFileSync(path, backupPath);
  return backupPath;
}

export interface LocalWriteOutcome {
  success: boolean; backupPath?: string; bytesWritten: number; error?: string;
}

// In-place write (preserves inode/permissions); roll back from backup on failure.
export function writeLocalFile(opts: {
  path: string; bytes: Buffer; append?: boolean; backup?: boolean;
  backupForTesting?: (path: string) => string;
}): LocalWriteOutcome {
  const path = opts.path;
  const bytes = opts.bytes;
  const append = !!opts.append;
  const wantBackup = opts.backup !== false;
  const exists = existsSync(path);

  if (append && !exists) {
    return { success: false, bytesWritten: 0, error:
      "append \u6A21\u5F0F\u8981\u6C42\u6587\u4EF6\u5DF2\u5B58\u5728\u3002\u8BF7\u5148\u7528 mode=write \u521B\u5EFA\u6587\u4EF6\uFF0C\u518D\u7528 mode=append \u8FFD\u52A0\u540E\u7EED\u5757\u3002" };
  }

  let backupPath: string | undefined;
  if (!append && wantBackup && exists) {
    try {
      backupPath = (opts.backupForTesting ?? backupLocalFile)(path);
    } catch (e: any) {
      const em = e && e.message ? e.message : String(e);
      return { success: false, bytesWritten: 0,
        error: "\u5907\u4EFD\u539F\u6587\u4EF6\u5931\u8D25: " + em + "\u3002\u5DF2\u4E2D\u6B62\u5199\u5165\uFF0C\u539F\u6587\u4EF6\u672A\u88AB\u4FEE\u6539\u3002" };
    }
  }

  try {
    if (!append) {
      const parent = dirname(path);
      if (parent !== "" && parent !== ".") mkdirSync(parent, { recursive: true });
    }
    writeFileSync(path, bytes, { flag: append ? "a" : "w" });
  } catch (e: any) {
    const msg = e && e.message ? e.message : String(e);
    if (backupPath !== undefined) {
      try {
        copyFileSync(backupPath, path);
        return { success: false, backupPath, bytesWritten: 0,
          error: "\u5199\u5165\u5931\u8D25: " + msg + "\n\u5DF2\u81EA\u52A8\u56DE\u6EDA\uFF1A\u539F\u6587\u4EF6\u5DF2\u4ECE\u5907\u4EFD " + backupPath + " \u6062\u590D\u3002" };
      } catch (re: any) {
        const rm2 = re && re.message ? re.message : String(re);
        return { success: false, backupPath, bytesWritten: 0,
          error: "\u5199\u5165\u5931\u8D25: " + msg + "\n\u56DE\u6EDA\u4E5F\u5931\u8D25: " + rm2 + "\u3002\u8BF7\u624B\u52A8\u7528\u5907\u4EFD " + backupPath + " \u6062\u590D " + path };
      }
    }
    return { success: false, bytesWritten: 0, error: "\u5199\u5165\u5931\u8D25: " + msg };
  }

  // Post-write verify: an interrupted write is shorter than expected; a silent
  // truncation is harder to debug than an error.
  let actual = bytes.length;
  try { actual = statSync(path).size; } catch { /* ignore */ }
  if (!append && actual !== bytes.length) {
    if (backupPath !== undefined) { try { copyFileSync(backupPath, path); } catch { /* ignore */ } }
    return { success: false, backupPath, bytesWritten: 0,
      error: "\u5199\u5165\u540E\u6821\u9A8C\u5931\u8D25\uFF1A\u671F\u671B " + bytes.length + " \u5B57\u8282\uFF0C\u5B9E\u9645 " + actual + " \u5B57\u8282\u3002" +
        (backupPath !== undefined
          ? "\u5DF2\u4ECE\u5907\u4EFD " + backupPath + " \u56DE\u6EDA\u3002"
          : "\u8BE5\u6587\u4EF6\u662F\u65B0\u5EFA\u7684\uFF0C\u65E0\u9700\u56DE\u6EDA\u3002") };
  }
  return { success: true, backupPath, bytesWritten: actual };
}

// Count non-overlapping occurrences of sub in str.
export function countOccurrences(str: string, sub: string): number {
  if (sub === "") return 0;
  let count = 0; let idx = 0;
  for (;;) {
    const found = str.indexOf(sub, idx);
    if (found < 0) break;
    count++;
    idx = found + sub.length;
  }
  return count;
}

export interface LocalPatchOutcome {
  success: boolean; error?: string; backupPath?: string; oldText?: string; newText?: string;
}

// Unique replace + a pre-write re-stat to avoid clobbering external edits.
export function patchLocalFile(opts: {
  path: string; oldText: string; newText: string; backup?: boolean;
}): LocalPatchOutcome {
  const path = opts.path; const oldText = opts.oldText; const newText = opts.newText;
  const wantBackup = opts.backup !== false;
  if (!existsSync(path)) {
    return { success: false, error: "\u6587\u4EF6\u4E0D\u5B58\u5728\uFF0C\u65E0\u6CD5\u505A\u5B57\u7B26\u4E32\u66FF\u6362\u3002\u8BF7\u5148\u786E\u8BA4\u8DEF\u5F84\u3002" };
  }
  if (oldText === "") {
    return { success: false, error: "old \u4E0D\u80FD\u4E3A\u7A7A" };
  }

  let statBefore: Stats | undefined;
  let original: string;
  try { statBefore = statSync(path); } catch { /* ignore */ }
  try { original = readFileSync(path, "utf-8"); }
  catch (e: any) {
    const em = e && e.message ? e.message : String(e);
    return { success: false, error: "\u8BFB\u53D6\u6587\u4EF6\u5931\u8D25\uFF08\u53EF\u80FD\u662F\u4E8C\u8FDB\u5236\u6587\u4EF6\u6216\u7F16\u7801\u4E0D\u662F UTF-8\uFF09: " + em };
  }

  const hits = countOccurrences(original, oldText);
  if (hits === 0) {
    return { success: false, error:
      "\u672A\u627E\u5230\u8981\u66FF\u6362\u7684\u5185\u5BB9\u3002\u8BF7\u5148\u7528 local_file_read \u786E\u8BA4\u539F\u6587\uFF08\u6CE8\u610F\u7F29\u8FDB\u4E0E\u6362\u884C\uFF09\u3002" };
  }
  if (hits > 1) {
    return { success: false, error:
      "\u8981\u66FF\u6362\u7684\u5185\u5BB9\u5728\u6587\u4EF6\u4E2D\u51FA\u73B0 " + hits + " \u6B21\uFF0C\u65E0\u6CD5\u5B9A\u4F4D\u3002\u8BF7\u63D0\u4F9B\u66F4\u957F\u7684\u4E0A\u4E0B\u6587\u4F7F\u5176\u552F\u4E00\u3002" };
  }

  // If it changed between read and write, abort to avoid clobbering others.
  let statNow: Stats | undefined;
  try { statNow = statSync(path); } catch { statNow = statBefore; }
  if (statBefore && statNow &&
      (statNow.size !== statBefore.size || statNow.mtimeMs !== statBefore.mtimeMs)) {
    return { success: false, error:
      "\u6587\u4EF6\u5728\u8BFB\u53D6\u540E\u88AB\u5916\u90E8\u4FEE\u6539\uFF08\u5927\u5C0F\u6216\u4FEE\u6539\u65F6\u95F4\u53D8\u4E86\uFF09\u3002\u5DF2\u4E2D\u6B62\u5199\u5165\uFF0C\u8BF7\u91CD\u65B0\u8BFB\u53D6\u540E\u518D\u8BD5\u3002" };
  }

  let backupPath: string | undefined;
  if (wantBackup) {
    try { backupPath = backupLocalFile(path); }
    catch (e: any) {
      const em = e && e.message ? e.message : String(e);
      return { success: false, error: "\u5907\u4EFD\u539F\u6587\u4EF6\u5931\u8D25: " + em + "\u3002\u5DF2\u4E2D\u6B62\u5199\u5165\uFF0C\u539F\u6587\u4EF6\u672A\u88AB\u4FEE\u6539\u3002" };
    }
  }

  const replaced = original.replace(oldText, newText); // replaceFirst
  const write = writeLocalFile({ path, bytes: Buffer.from(replaced, "utf-8"), backup: false });
  if (!write.success) {
    return { success: false, backupPath, error: write.error, oldText, newText };
  }
  return { success: true, backupPath: backupPath ?? write.backupPath, oldText, newText };
}

// ---- trash helpers ----
export interface TrashUsage { entries: string[]; bytes: number; }
export interface TrashClearResult {
  removed: number; bytesFreed: number; refused: string[]; failed: string[];
}

// Is the path a "trash entry dir": under .ai_terminal_trash, exactly one level
// deeper (the <stamp> level), but not the trash root itself.
export function isTrashEntryDir(path: string, opts?: { trashDirName?: string }): boolean {
  const name = opts?.trashDirName ?? TRASH_DIR_NAME;
  const segments = normalize(path).split(sep).filter((s) => s.length > 0);
  const index = segments.lastIndexOf(name);
  return index >= 0 && index === segments.length - 2;
}

// Dedup + sort the trash entry dirs implied by recorded localRestoreFrom paths.
export function trashEntriesFromRestorePaths(
  restorePaths: Iterable<string>, opts?: { trashDirName?: string }): string[] {
  const name = opts?.trashDirName ?? TRASH_DIR_NAME;
  const set = new Set<string>();
  for (const rp of restorePaths) {
    if (rp.trim() === "") continue;
    const entry = dirname(normalize(rp));
    if (isTrashEntryDir(entry, { trashDirName: name })) set.add(entry);
  }
  return [...set].sort();
}

function directoryBytes(dir: string): number {
  let total = 0;
  const stack: string[] = [dir];
  while (stack.length > 0) {
    const d = stack.pop() as string;
    let ents: string[];
    try { ents = readdirSync(d, { withFileTypes: true }).map((e) => e.name); }
    catch { continue; }
    for (const e of ents) {
      const full = join(d, e);
      let st: Stats; try { st = statSync(full); } catch { continue; }
      if (st.isDirectory() && !st.isSymbolicLink()) stack.push(full);
      else if (st.isFile()) total += st.size;
    }
  }
  return total;
}

export function measureTrashEntries(entries: string[]): TrashUsage {
  const live: string[] = []; let bytes = 0;
  for (const e of entries) { if (existsSync(e)) { live.push(e); bytes += directoryBytes(e); } }
  return { entries: live, bytes };
}

// Re-validate each entry as a trash dir before deleting: a wrong caller (or
// polluted ledger data) must be refused, never hand-delete a real dir.
export function clearTrashEntries(
  entries: string[], opts?: { trashDirName?: string }): TrashClearResult {
  const name = opts?.trashDirName ?? TRASH_DIR_NAME;
  const refused: string[] = []; const failed: string[] = [];
  let removed = 0; let bytesFreed = 0;
  for (const e of entries) {
    if (!isTrashEntryDir(e, { trashDirName: name })) { refused.push(e); continue; }
    if (!existsSync(e)) continue;
    const size = directoryBytes(e);
    try { rmSync(e, { recursive: true, force: true }); removed++; bytesFreed += size; }
    catch (err: any) {
      const em = err && err.message ? err.message : String(err);
      failed.push(e + "\uFF08" + em + "\uFF09");
    }
  }
  return { removed, bytesFreed, refused, failed };
}

// Human-readable byte sizes, for "trash is about N bytes" style messages.
export function formatByteSize(bytes: number): string {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB";
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB";
}

function isWithin(root: string, target: string): boolean {
  const rr = normalize(root); const tt = normalize(target);
  if (rr === tt) return false;
  const prefix = rr.endsWith(sep) ? rr : rr + sep;
  return tt.startsWith(prefix);
}

// How many restore paths land under these trash entries.
export function countPathsUnderEntries(
  restorePaths: Iterable<string>, entries: string[]): number {
  if (entries.length === 0) return 0;
  let count = 0;
  for (const rp of restorePaths) {
    if (rp.trim() === "") continue;
    const p = normalize(rp);
    for (const e of entries) { if (isWithin(e, p)) { count++; break; } }
  }
  return count;
}

// Looks like a local Windows path (D:\x / C:/x).
export function looksLikeWindowsLocalPath(path: string): boolean {
  return /^[A-Za-z]:[\\/]/.test(path.trim());
}

// Looks like a remote POSIX path (/etc/x, ~/x).
export function looksLikePosixRemotePath(path: string): boolean {
  const t = path.trim();
  return t.startsWith("/") || t.startsWith("~/");
}
