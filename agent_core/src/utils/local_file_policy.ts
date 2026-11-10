// local_file_policy.ts - 1:1 port of Dart
// ai_terminal/lib/services/local_file_policy.dart (262 lines). The scope policy in
// front of every local_* file tool: a user-maintained allowlist plus a sensitive-
// path blacklist. Dart enforces it at local_file_tools.dart:29 (every path an AI
// hands a local_* tool goes through decide() before any I/O) and the blacklist half
// is the SafetyGuard.checkPath call at local_file_policy.dart:147, which is the
// exact site this file recreates - before it existed src/utils/safety_guard.ts had
// no caller anywhere on the Node side, which is what section 9 item 7 was still
// holding open.
//
// Two gates, neither optional (Dart doc 40-45): the allowlist decides which doors
// may be entered at all and defaults to EMPTY - a fresh install authorises nothing,
// so read of any file is denied until the user adds a directory. The blacklist
// reuses checkPath and runs SECOND because it outranks the allowlist: a user who
// whitelists their whole home directory must still be refused
// ~/.ssh/authorized_keys, otherwise local write access on the box equals persistence
// on the box. The blacklist verdict is checked before the allowlist roots so that a
// sensitive path never reaches the "is it within a root" loop.
//
// Node port notes, disclosed rather than silently diverged:
//   * Dart LocalFilePolicy.load() reads SettingsDao.getCached("localFilePolicy").
//     agent_core is a headless core with no SettingsDao and no 设置 page, so load()
//     takes an injected settings reader instead; a throw or a non-object is treated
//     as DISABLED exactly like Dart ("绝不因为解析失败就放开文件访问"), and the
//     default policy is deny-all.
//   * Dart _homeDir reads HOME then USERPROFILE; reproduced via process.env.
//   * Dart p.posix/path helpers are reproduced with node:path so that the compare
//     normalisation and the Windows case-insensitivity match Dart byte for byte.
//   * The reserved-verdict (回收区) is emitted by decide(), but as in Dart the
//     delete tool itself writes the trash by rename and never through decide(), so
//     the reserved guard only blocks direct AI access, never delete/restore.
import * as nodePath from "node:path";
import {lstatSync, realpathSync} from "node:fs";
import {checkPath} from "./safety_guard.js";

export enum LocalPathVerdict {
  allowed = "allowed",
  notInAllowlist = "notInAllowlist",
  sensitive = "sensitive",
  escape = "escape",
  reserved = "reserved",
}

export class LocalPathDecision {
  constructor(
    readonly verdict: LocalPathVerdict,
    readonly resolved: string,
    readonly reason?: string,
  ) {}
  get isAllowed(): boolean { return this.verdict === LocalPathVerdict.allowed; }
}

export interface LocalFilePolicyOptions {
  enabled?: boolean;
  allowedDirs?: string[];
  maxReadBytes?: number;
  // Node-only: see the disclose comment on the field below.
  trustedHost?: boolean;
}

// A settings reader stands in for Dart SettingsDao.getCached. Returning
// undefined (or throwing) means "no usable config", which the constructor turns
// into a deny-all policy.
export type LocalFileSettingsReader = (key: string) => unknown;

export const LOCAL_FILE_POLICY_SETTINGS_KEY = "localFilePolicy";
export const DEFAULT_MAX_READ_BYTES = 2 * 1024 * 1024;

export class LocalFilePolicy {
  // Dart static const String trashDirName = ".ai_terminal_trash"; must stay byte-
  // equal to TRASH_DIR_NAME in local_file_ops.ts - the delete tool renames into a
  // directory of this name, and decide() refuses anything whose segments contain it.
  static readonly trashDirName = ".ai_terminal_trash";

  readonly enabled: boolean;
  readonly allowedDirs: string[];
  readonly maxReadBytes: number;
  // Node-only divergence, disclosed rather than silently invented. Dart has no
  // trustedHost flag: on the desktop the allowlist is what the user turns on via the
  // settings page, and an empty allowlist means deny-all. agent_core historically
  // treated the host as trusted and did no path gating at all, so a Node embedder
  // that wants that posture turns trustedHost on: the allowlist step is skipped, but
  // the reserved-trash check and the checkPath blacklist still run FIRST, so a
  // sensitive path (ssh key, .env, a system directory) is refused under every mode.
  // trustedHost widens the allowlist only, never the blacklist.
  readonly trustedHost: boolean;

  constructor(opts: LocalFilePolicyOptions = {}) {
    this.enabled = opts.enabled ?? false;
    this.allowedDirs = opts.allowedDirs ?? [];
    this.maxReadBytes = opts.maxReadBytes ?? DEFAULT_MAX_READ_BYTES;
    this.trustedHost = opts.trustedHost ?? false;
  }

  static load(reader?: LocalFileSettingsReader): LocalFilePolicy {
    if (reader === undefined) return new LocalFilePolicy();
    try {
      const raw = reader(LOCAL_FILE_POLICY_SETTINGS_KEY);
      if (raw !== null && typeof raw === "object" && !Array.isArray(raw)) {
        return LocalFilePolicy.fromMap(raw as Record<string, unknown>);
      }
    } catch {
      // Dart: 配置解析失败按"未授权"处理，绝不因为解析失败就放开文件访问
      return new LocalFilePolicy();
    }
    return new LocalFilePolicy();
  }

  toMap(): Record<string, unknown> {
    return {
      enabled: this.enabled,
      allowedDirs: this.allowedDirs,
      maxReadBytes: this.maxReadBytes,
      trustedHost: this.trustedHost,
    };
  }

  static fromMap(map: Record<string, unknown>): LocalFilePolicy {
    const dirs = Array.isArray(map.allowedDirs)
      ? (map.allowedDirs as unknown[]).map((e) => String(e))
      : [];
    return new LocalFilePolicy({
      enabled: map.enabled === true,
      allowedDirs: dirs,
      maxReadBytes: typeof map.maxReadBytes === "number" ? map.maxReadBytes : DEFAULT_MAX_READ_BYTES,
      trustedHost: map.trustedHost === true,
    });
  }

  copyWith(opts: LocalFilePolicyOptions): LocalFilePolicy {
    return new LocalFilePolicy({
      enabled: opts.enabled ?? this.enabled,
      allowedDirs: opts.allowedDirs ?? this.allowedDirs,
      maxReadBytes: opts.maxReadBytes ?? this.maxReadBytes,
      trustedHost: opts.trustedHost ?? this.trustedHost,
    });
  }

  decide(rawPath: string, extraRoots: string[] = []): LocalPathDecision {
    if (rawPath.trim().length === 0) {
      return new LocalPathDecision(LocalPathVerdict.notInAllowlist, "", "路径为空");
    }
    // trustedHost implies the master switch is on: an embedder that turns it on
    // has chosen the trusted posture, so the not-enabled refusal must not fire.
    // It only skips the allowlist roots further down, never the blacklist.
    if (!this.enabled && !this.trustedHost) {
      return new LocalPathDecision(
        LocalPathVerdict.notInAllowlist, rawPath,
        "本地文件访问未开启。请在 设置 → Agent → 本地文件 中添加允许访问的目录。",
      );
    }

    const absolute = this.resolveNoFollow(this.expand(rawPath));
    const lexical = nodePath.normalize(absolute);

    // 0. reserved 回收区先拒 (Dart 136-144): the delete tool writes it itself, so
    // direct AI access would break the "deleted, but still recoverable" premise.
    if (lexical.split(/[\\/]/).includes(LocalFilePolicy.trashDirName)) {
      return new LocalPathDecision(
        LocalPathVerdict.reserved, lexical,
        LocalFilePolicy.trashDirName + " 是回收区，只能由删除工具自身写入，不能直接访问。",
      );
    }

    // 1. blacklist outranks the allowlist - this is local_file_policy.dart:147.
    const safety = checkPath(lexical);
    if (safety.level === "blocked") {
      return new LocalPathDecision(
        LocalPathVerdict.sensitive, lexical, safety.reason ?? "敏感路径");
    }

    // trustedHost (Node-only) skips the allowlist step but is reached only after
    // trash-reserved and the checkPath blacklist above, so sensitive paths never
    // arrive here. This is the honest shape of the historical "host trusted" posture:
    // every path is authorised except the ones the blacklist refuses.
    if (this.trustedHost) {
      return new LocalPathDecision(LocalPathVerdict.allowed, lexical);
    }

    // 2. allowlist roots (Dart 153-175)
    const roots = [...this.allowedDirs, ...extraRoots]
      .filter((r) => r.trim().length > 0)
      .map((r) => this.normalizeForCompare(this.resolveNoFollow(this.expand(r))));
    if (roots.length === 0) {
      return new LocalPathDecision(
        LocalPathVerdict.notInAllowlist, lexical, "尚未配置任何允许访问的目录。");
    }
    const probe = this.normalizeForCompare(lexical);
    for (const root of roots) {
      if (this.isWithin(probe, root)) {
        return new LocalPathDecision(LocalPathVerdict.allowed, lexical);
      }
    }
    return new LocalPathDecision(
      LocalPathVerdict.notInAllowlist, lexical,
      "路径不在授权目录内。当前授权: " + this.allowedDirs.join(", "),
    );
  }

  get roots(): string[] { return this.allowedDirs; }

  // ---- internals, mirroring the Dart private helpers 1:1 ----

  private expand(path: string): string {
    let s = path.trim();
    if (s === "~" || s.startsWith("~/") || s.startsWith("~" + String.fromCharCode(92))) {
      const home = LocalFilePolicy.homeDir();
      if (home !== null) {
        const rest = s.slice(1).replace(new RegExp("^[\\/\\\\]"), "");
        s = nodePath.join(home, rest);
      }
    }
    if (!nodePath.isAbsolute(s)) {
      s = nodePath.join(process.cwd(), s);
    }
    return s;
  }

  private static homeDir(): string | null {
    return process.env.HOME ?? process.env.USERPROFILE ?? null;
  }

  private normalizeForCompare(path: string): string {
    let s = nodePath.normalize(path).split("\\").join("/");
    if (process.platform === "win32") s = s.toLowerCase();
    return s.endsWith("/") && s.length > 1 ? s.slice(0, s.length - 1) : s;
  }

  private isWithin(child: string, root: string): boolean {
    if (child === root) return true;
    return child.startsWith(root + "/");
  }

  // Resolve symlinks against the deepest EXISTING ancestor, then re-attach the
  // missing tail (Dart 214-247). A dangling link counts as existing, otherwise the
  // walk runs to the root and the guard stops working. Resolution failures fall back
  // to the literal path, never to "allow" - the literal still faces both gates.
  private resolveNoFollow(absolute: string): string {
    const normalized = nodePath.normalize(absolute);
    const missing: string[] = [];
    let cursor = normalized;

    while (!LocalFilePolicy.exists(cursor)) {
      const parent = nodePath.dirname(cursor);
      if (parent === cursor) break;
      missing.unshift(nodePath.basename(cursor));
      cursor = parent;
    }

    let real = cursor;
    try {
      real = realpathSync(cursor);
    } catch {
      // keep the literal cursor as the real path
    }

    if (missing.length === 0) return nodePath.normalize(real);
    return nodePath.normalize(nodePath.join(real, ...missing));
  }

  private static exists(path: string): boolean {
    try {
      // lstatSync does not follow the final link, so a dangling link still counts
      // (Dart checks File/Directory/Link separately for exactly this reason).
      lstatSync(path);
      return true;
    } catch {
      return false;
    }
  }
}
