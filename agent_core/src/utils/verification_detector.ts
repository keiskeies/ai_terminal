// verification_detector.ts - 1:1 port of Dart ai_terminal/lib/utils/verification_detector.dart (88L).
// Deterministic verification badge detector for systemctl / ss / netstat / nginx -t / curl.
// Identifies a small set of format-stable read-only verification commands and produces
// "running / port listening / config passed" badges. If it can't identify, it produces
// nothing - never lets the model guess a state.

import type {OperationBadge} from "../rpc/schema.js";

export class VerificationDetector {
  static detect(options: {
    command: string;
    output?: string | null;
    success: boolean;
  }): OperationBadge | null {
    const cmd = options.command.trim();
    const out = (options.output ?? "").trim();
    if (cmd === "") return null;

    // systemctl is-active
    const isActive = /systemctl\s+is-active\s+(\S+)/.exec(cmd);
    if (isActive) {
      const service = isActive[1] ?? "\u670d\u52a1"; // 服务
      const state = firstLine(out).toLowerCase();
      if (state === "active") {
        return {text: service + " \u8fd0\u884c\u4e2d", level: "success"}; // $service 运行中
      }
      if (state === "inactive" || state === "failed" || state === "unknown") {
        return {text: service + " \u672a\u8fd0\u884c", level: "warning"}; // $service 未运行
      }
      return null;
    }

    // systemctl is-enabled
    const isEnabled = /systemctl\s+is-enabled\s+(\S+)/.exec(cmd);
    if (isEnabled) {
      const service = isEnabled[1] ?? "\u670d\u52a1";
      const state = firstLine(out).toLowerCase();
      if (state === "enabled") {
        return {text: service + " \u5f00\u673a\u81ea\u542f", level: "success"}; // $service 开机自启
      }
      if (state === "disabled") {
        return {text: service + " \u672a\u8bbe\u7f6e\u81ea\u542f", level: "info"}; // $service 未设置自启
      }
      return null;
    }

    // ss -l / netstat -l (port listening)
    if (/^ss\s+.*-l/.test(cmd) || /^netstat\s+.*-l/.test(cmd)) {
      const ports = new Set<string>();
      for (const line of out.split("\n")) {
        if (!line.toUpperCase().includes("LISTEN")) continue;
        for (const m of line.matchAll(/:(\d{1,5})\s/g)) {
          const port = parseInt(m[1], 10);
          if (port > 0 && port <= 65535) {
            ports.add(port.toString());
          }
        }
      }
      if (ports.size === 0) return null;
      const sorted = [...ports].map(Number).sort((a, b) => a - b);
      const shown = sorted.slice(0, 4).join("/");
      const suffix = sorted.length > 4 ? " \u7b49 " + sorted.length + " \u4e2a\u7aef\u53e3" : ""; // 等 N 个端口
      return {text: "\u7aef\u53e3 " + shown + suffix + " \u76d1\u542c", level: "success"}; // 端口 $shown$suffix 监听
    }

    // nginx -t
    if (cmd.includes("nginx -t")) {
      return options.success
        ? {text: "Nginx \u914d\u7f6e\u68c0\u67e5\u901a\u8fc7", level: "success"} // Nginx 配置检查通过
        : {text: "Nginx \u914d\u7f6e\u68c0\u67e5\u5931\u8d25", level: "warning"}; // Nginx 配置检查失败
    }

    // curl
    if (cmd.includes("curl ")) {
      const m = /HTTP\/\S+\s+(\d{3})/.exec(out);
      const status = m?.[1];
      if (status !== undefined) {
        const code = parseInt(status, 10) || 0;
        return {text: "HTTP " + status, level: code >= 200 && code < 400 ? "success" : "warning"};
      }
      return null;
    }

    return null;
  }
}

function firstLine(text: string): string {
  const idx = text.indexOf("\n");
  return (idx < 0 ? text : text.substring(0, idx)).trim();
}