// verification_detector.test.ts - oracle-replay test for src/utils/verification_detector.ts
// Mirrors Dart ai_terminal/test/verification_detector_test.dart (97 lines).

import {describe, it, expect} from "vitest";
import {VerificationDetector} from "../src/utils/verification_detector.js";

describe("VerificationDetector (Dart oracle: verification_detector_test.dart)", () => {
  it("systemctl is-active active/inactive", () => {
    const active = VerificationDetector.detect({
      command: "systemctl is-active nginx",
      output: "active\n",
      success: true,
    });
    expect(active?.text).toBe("nginx \u8fd0\u884c\u4e2d"); // nginx 运行中
    expect(active?.level).toBe("success");

    const inactive = VerificationDetector.detect({
      command: "systemctl is-active nginx",
      output: "inactive\n",
      success: false,
    });
    expect(inactive?.text).toBe("nginx \u672a\u8fd0\u884c"); // nginx 未运行
    expect(inactive?.level).toBe("warning");
  });

  it("systemctl is-enabled", () => {
    const badge = VerificationDetector.detect({
      command: "systemctl is-enabled nginx",
      output: "enabled",
      success: true,
    });
    expect(badge?.text).toBe("nginx \u5f00\u673a\u81ea\u542f"); // nginx 开机自启
    expect(badge?.level).toBe("success");
  });

  it("ss listening ports", () => {
    const output = [
      "State  Recv-Q Send-Q Local Address:Port  Peer Address:Port",
      "LISTEN 0      511          0.0.0.0:80         0.0.0.0:*",
      "LISTEN 0      511             [::]:443           [::]:*",
    ].join("\n");
    const badge = VerificationDetector.detect({
      command: "ss -lntp",
      output,
      success: true,
    });
    expect(badge?.text).toBe("\u7aef\u53e3 80/443 \u76d1\u542c"); // 端口 80/443 监听
    expect(badge?.level).toBe("success");
  });

  it("nginx -t", () => {
    const ok = VerificationDetector.detect({
      command: "nginx -t",
      output: "syntax is ok",
      success: true,
    });
    expect(ok?.text).toBe("Nginx \u914d\u7f6e\u68c0\u67e5\u901a\u8fc7"); // Nginx 配置检查通过

    const failed = VerificationDetector.detect({
      command: "nginx -t",
      output: "syntax error",
      success: false,
    });
    expect(failed?.text).toBe("Nginx \u914d\u7f6e\u68c0\u67e5\u5931\u8d25"); // Nginx 配置检查失败
    expect(failed?.level).toBe("warning");
  });

  it("curl HTTP status", () => {
    const ok = VerificationDetector.detect({
      command: "curl -I https://example.com",
      output: "HTTP/2 200\nserver: nginx",
      success: true,
    });
    expect(ok?.text).toBe("HTTP 200");
    expect(ok?.level).toBe("success");
  });

  it("empty command returns null", () => {
    const badge = VerificationDetector.detect({
      command: "   ",
      output: "anything",
      success: true,
    });
    expect(badge).toBeNull();
  });

  it("unknown command returns null", () => {
    const badge = VerificationDetector.detect({
      command: "ls -la",
      output: "total 0",
      success: true,
    });
    expect(badge).toBeNull();
  });
});
