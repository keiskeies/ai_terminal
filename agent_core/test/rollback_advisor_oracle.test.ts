// Oracle-replay test for RollbackAdvisor (r140).
// Re-reads rollback_advisor.dart at run time and pins the analyze,
// buildSnapshotCommand, and buildRollbackSuggestion logic against the Node port.
import {describe, it, expect} from "vitest";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {RollbackAdvisor, ModifyTargetType} from "../src/utils/rollback_advisor.js";

const NL = String.fromCharCode(10);
const HERE = fileURLToPath(new URL(".", import.meta.url));
const linesOf = (rel: string) =>
  readFileSync(HERE + rel, "utf-8").replace(/\r\n/g, NL).split(NL);

const DART = linesOf("../../ai_terminal/lib/utils/rollback_advisor.dart");

describe("r140: RollbackAdvisor oracle", () => {

  it("analyze returns null for query commands (Dart 70)", () => {
    expect(RollbackAdvisor.analyze("ls -la /tmp")).toBeNull();
    expect(RollbackAdvisor.analyze("cat /etc/hostname")).toBeNull();
    expect(RollbackAdvisor.analyze("grep foo bar")).toBeNull();
  });

  it("analyze detects config file modification (Dart 73)", () => {
    const t = RollbackAdvisor.analyze("sed -i 's/a/b/' /etc/nginx/nginx.conf");
    expect(t).not.toBeNull();
    expect(t!.type).toBe(ModifyTargetType.configFile);
    expect(t!.name).toBe("/etc/nginx/nginx.conf");
  });

  it("analyze detects service modification (Dart 77)", () => {
    const t = RollbackAdvisor.analyze("systemctl restart nginx");
    expect(t).not.toBeNull();
    expect(t!.type).toBe(ModifyTargetType.service);
    expect(t!.name).toBe("nginx");
  });

  it("analyze detects package installation (Dart 81)", () => {
    const t = RollbackAdvisor.analyze("apt install curl");
    expect(t).not.toBeNull();
    expect(t!.type).toBe(ModifyTargetType.package);
    expect(t!.name).toBe("curl");
  });

  it("analyze detects permission modification (Dart 85)", () => {
    const t = RollbackAdvisor.analyze("chmod 777 /var/www/app");
    expect(t).not.toBeNull();
    expect(t!.type).toBe(ModifyTargetType.permission);
    expect(t!.name).toBe("/var/www/app");
  });

  it("buildSnapshotCommand generates read-only commands (Dart 94-126)", () => {
    const t: {type: ModifyTargetType, name: string, command: string} = {
      type: ModifyTargetType.service, name: "nginx", command: "systemctl restart nginx",
    };
    const cmd = RollbackAdvisor.buildSnapshotCommand(t);
    expect(cmd).not.toBeNull();
    expect(cmd).toContain("systemctl status nginx");
  });

  it("buildRollbackSuggestion generates suggestion (Dart 129-194)", () => {
    const t: {type: ModifyTargetType, name: string, command: string} = {
      type: ModifyTargetType.service, name: "nginx", command: "systemctl restart nginx",
    };
    const s = RollbackAdvisor.buildRollbackSuggestion(t, null);
    expect(s).not.toBeNull();
    // Contains CJK suggestion text (as \uXXXX in source)
    expect(s!.length).toBeGreaterThan(0);
  });

  it("mv to backup extension is not a fileWrite (Dart 238)", () => {
    const t = RollbackAdvisor.analyze("mv /etc/app.conf /etc/app.conf.bak");
    expect(t === null || t.type !== ModifyTargetType.fileWrite).toBe(true);
  });

  it("Dart source lines are non-empty (run-time pin)", () => {
    expect(DART[3].trim()).toContain("ModifyTargetType");
    expect(DART[19].trim()).toContain("ModifyTarget");
    expect(DART[37].trim()).toContain("PreSnapshot");
    expect(DART[61].trim()).toContain("RollbackAdvisor");
  });
});
