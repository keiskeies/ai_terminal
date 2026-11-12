// AgentLogger - port of Dart agent_logger.dart 1-207.
//
// Circular buffer (1000 entries) + 500ms async file flush + 5MB/2MB rotation.
// In the Node port: no Flutter path_provider, no debugPrint, no Zones.
// - File path is injected via setLogFile() (default: no file, console-only).
// - Console output uses console.log (debug mode) or console.warn/error (always).
// - Zone-based conversation routing is replaced by an explicit setCurrentConversation().
import {appendFileSync, readFileSync, statSync, writeFileSync, renameSync} from "node:fs";
import {mkdirSync} from "node:fs";
import {dirname} from "node:path";

export type LogListener = (
  level: string,
  tag: string,
  message: string,
  timestamp: Date,
  hostId?: string | null,
  conversationId?: string | null,
) => void;

export class AgentLogger {
  private static _instance: AgentLogger | null = null;
  static get instance(): AgentLogger {
    if (!AgentLogger._instance) AgentLogger._instance = new AgentLogger();
    return AgentLogger._instance;
  }
  private constructor() {}

  // Dart 23-24: circular buffer, max 1000 entries
  private readonly _logs: string[] = [];
  private static readonly MAX_LOGS = 1000;

  // Dart 26: log file path (injected, not Flutter path_provider)
  private _logFile: string | null = null;

  // Dart 30: current host routing
  currentHostId: string | null = null;

  // Dart 34-48: Zone-based conversation routing replaced by explicit setter
  private _currentConversationId: string | null = null;
  setCurrentConversation(conversationId: string | null): void {
    this._currentConversationId = conversationId;
  }
  getCurrentConversation(): string | null {
    return this._currentConversationId;
  }

  // Dart 51-53: file write buffer + 500ms flush timer
  private _fileBuffer = "";
  private _flushTimer: ReturnType<typeof setTimeout> | null = null;
  private _fileWriting = false;

  // Dart 148-149: log rotation thresholds
  private static readonly MAX_LOG_SIZE = 5 * 1024 * 1024;
  private static readonly KEEP_LOG_SIZE = 2 * 1024 * 1024;

  // Dart 185: listeners (copied before iteration to avoid concurrent modification)
  private readonly _listeners: LogListener[] = [];

  // Node: set the log file path (replaces Dart's _initLogFileAsync which uses path_provider)
  setLogFile(path: string): void {
    const dir = dirname(path);
    try { mkdirSync(dir, {recursive: true}); } catch { /* ignore */ }
    appendFileSync(path, "\n=== Agent Log Started " + new Date().toISOString() + " ===\n");
    this._logFile = path;
  }

  // Dart 78-107: log entry (circular buffer + console + file + listeners)
  log(level: string, tag: string, message: string): void {
    const timestamp = new Date();
    const logEntry = "[" + timestamp.toISOString() + "] [" + level + "] [" + tag + "] " + message;

    // Circular buffer (Dart 83-84: addLast + removeFirst when over capacity)
    this._logs.push(logEntry);
    if (this._logs.length > AgentLogger.MAX_LOGS) this._logs.shift();

    // Console output (Dart 87-89: WARN/ERROR always, DEBUG/INFO in debug mode)
    const isDebug = process.env["NODE_ENV"] !== "production";
    if (level === "WARN" || level === "ERROR") {
      console.warn(logEntry);
    } else if (isDebug) {
      console.log(logEntry);
    }

    // File write: buffer + 500ms flush (Dart 92-93)
    this._fileBuffer += logEntry + String.fromCharCode(10);
    this._scheduleFlush();

    // Notify listeners (Dart 97-106: copy list to avoid concurrent modification)
    if (this._listeners.length > 0) {
      const conversationId = this._currentConversationId;
      const listeners = this._listeners.slice();
      for (const l of listeners) {
        try {
          l(level, tag, message, timestamp, this.currentHostId, conversationId);
        } catch (e) {
          console.warn("[AgentLogger] listener error: " + String(e));
        }
      }
    }
  }

  // Dart 110-113: schedule 500ms flush
  private _scheduleFlush(): void {
    if (this._flushTimer !== null) return;
    this._flushTimer = setTimeout(() => { void this._flushToFile(); }, 500);
  }

  // Dart 115-145: flush file buffer (with re-schedule on write-in-progress)
  private async _flushToFile(): Promise<void> {
    this._flushTimer = null;
    if (this._fileWriting) { this._scheduleFlush(); return; }
    const file = this._logFile;
    if (!file || this._fileBuffer.length === 0) {
      // Dart 125-127: clear buffer if file init failed to prevent OOM
      if (!file && this._fileBuffer.length > 10000) this._fileBuffer = "";
      return;
    }
    const pending = this._fileBuffer;
    this._fileBuffer = "";
    this._fileWriting = true;
    try {
      appendFileSync(file, pending);
      await this._rotateIfNeeded(file);
    } catch (e) {
      console.warn("[AgentLogger] file write failed: " + String(e));
      this._fileBuffer = pending + this._fileBuffer;
    } finally {
      this._fileWriting = false;
    }
  }

  // Dart 151-170: log rotation (5MB -> keep tail 2MB, atomic tmp+rename)
  private async _rotateIfNeeded(file: string): Promise<void> {
    try {
      const size = statSync(file).size;
      if (size < AgentLogger.MAX_LOG_SIZE) return;
      const data = readFileSync(file);
      const tail = data.subarray(Math.max(0, data.length - AgentLogger.KEEP_LOG_SIZE));
      const tmpFile = file + ".tmp";
      writeFileSync(tmpFile, tail);
      renameSync(tmpFile, file);
    } catch (e) {
      console.warn("[AgentLogger] rotation failed: " + String(e));
    }
  }

  // Dart 172-175: convenience methods
  debug(tag: string, message: string): void { this.log("DEBUG", tag, message); }
  info(tag: string, message: string): void { this.log("INFO", tag, message); }
  warn(tag: string, message: string): void { this.log("WARN", tag, message); }
  error(tag: string, message: string): void { this.log("ERROR", tag, message); }

  // Dart 178-180: get logs (oldest first, newest last)
  getLogs(): readonly string[] { return this._logs.slice(); }
  getLogsAsString(): string { return this._logs.join(String.fromCharCode(10)); }

  // Dart 190-196: subscribe (returns unsubscribe function)
  subscribe(listener: LogListener): () => void {
    this._listeners.push(listener);
    return () => {
      const idx = this._listeners.indexOf(listener);
      if (idx >= 0) this._listeners.splice(idx, 1);
    };
  }

  // Dart 199-203: flush all buffered logs (call on app exit)
  async flush(): Promise<void> {
    if (this._flushTimer !== null) { clearTimeout(this._flushTimer); this._flushTimer = null; }
    await this._flushToFile();
  }
}

// Dart 206: singleton export
export const agentLogger = AgentLogger.instance;
