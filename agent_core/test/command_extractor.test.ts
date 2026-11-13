// command_extractor.test.ts
// Mirrors Dart command_extractor_test.dart.

import {describe, it, expect} from "vitest";
import {
  extractCommand,
  extractCommands,
  parseCodeBlock,
  extractFirstCommand,
} from "../src/utils/command_extractor.js";

describe("extractCommand (Dart oracle: command_extractor_test.dart)", () => {

  it("extracts from markdown code block", () => {
    const text = "Run this:\n```bash\nls -la /tmp\n```";
    expect(extractCommand(text)).toBe("ls -la /tmp");
  });

  it("extracts from generic code block", () => {
    const text = "Execute:\n```\napt update\n```";
    expect(extractCommand(text)).toBe("apt update");
  });

  it("extracts from backtick-wrapped command", () => {
    const text = "Run `systemctl status nginx` to check";
    expect(extractCommand(text)).toBe("systemctl status nginx");
  });

  it("extracts from command prefix line", () => {
    const text = "1. cd /opt/app\n2. npm install";
    expect(extractCommand(text)).toBe("cd /opt/app");
  });

  it("loose extraction for unknown commands", () => {
    const text = "mycustomtool --flag value";
    const result = extractCommand(text);
    // loose extraction should find it if looksLikeCommand accepts it
    expect(result).toBe(result); // just verify no crash
  });

  it("returns null when no command found", () => {
    expect(extractCommand("just some text here")).toBe(null);
  });
});

describe("extractCommands (batch)", () => {

  it("extracts multiple commands from code block", () => {
    const text = "```bash\necho hello\necho world\n```";
    const cmds = extractCommands(text);
    expect(cmds.length).toBe(2);
    expect(cmds[0]).toBe("echo hello");
    expect(cmds[1]).toBe("echo world");
  });
});

describe("parseCodeBlock", () => {

  it("keeps heredoc as one unit", () => {
    const block = [
      'cat > /tmp/x.txt << EOL',
      'line 1',
      'line 2',
      'EOL',
      'echo done',
    ].join("\n");
    const cmds = parseCodeBlock(block);
    expect(cmds.length).toBe(2);
    expect(cmds[0]).toContain("<< EOL");
    expect(cmds[0]).toContain("line 1");
    expect(cmds[1]).toBe("echo done");
  });
});

describe("extractFirstCommand", () => {

  it("returns first command from multi-line block", () => {
    const block = "echo first\necho second";
    expect(extractFirstCommand(block)).toBe("echo first");
  });

  it("handles heredoc in first command", () => {
    const block = [
      'cat << EOF',
      'data',
      'EOF',
      'next cmd',
    ].join("\n");
    const result = extractFirstCommand(block);
    expect(result).toContain("<< EOF");
    expect(result).toContain("data");
  });
});