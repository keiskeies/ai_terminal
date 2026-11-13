// form_validators.test.ts - 1:1 port of Dart form_validators.dart literals
// (all 5 validators + combine). Dart has no test for this file; the test
// pins the exact error strings so a future rewrite cannot silently change
// the UI-facing wording.
import {describe, it, expect} from "vitest";
import {FormValidators} from "../src/utils/form_validators.js";

describe("FormValidators (Dart literals, byte-faithful)", () => {
  it("required: null / blank -> '<field> 不能为空'; value -> pass", () => {
    expect(FormValidators.required(null).error).toBe("此字段 不能为空");
    expect(FormValidators.required("  ", "主机").error).toBe("主机 不能为空");
    expect(FormValidators.required("127.0.0.1", "主机").error).toBeNull();
  });

  it("maxLength: over max -> '<field> 不能超过 <max> 个字符'", () => {
    expect(FormValidators.maxLength("12345", 3, "标签").error).toBe("标签 不能超过 3 个字符");
    expect(FormValidators.maxLength("123", 3).error).toBeNull();
    expect(FormValidators.maxLength(null, 3).error).toBeNull(); // null passes
  });

  it("host: accepts IPv4 dotted-quad and DNS domain", () => {
    expect(FormValidators.host("127.0.0.1").error).toBeNull();
    // Dart ipRegex requires exactly 4 dotted octets, but the domain regex
// accepts 1-2-3 all-digit "labels" too - pin both branches of the OR:
expect(FormValidators.host("10.0.0").error).toBeNull(); // 3 all-digit labels pass the domain regex
expect(FormValidators.host("1.2.3.4.5").error).toBeNull(); // domain regex has no segment-count cap - Dart passes it too
expect(FormValidators.host("-bad").error).toBe("请输入有效的 IP 地址或域名"); // leading dash fails both regexes
expect(FormValidators.host("300.0.0.1").error).toBeNull(); // Dart ipRegex has no range check
    expect(FormValidators.host("example.com").error).toBeNull();
    expect(FormValidators.host("my-host.local").error).toBeNull();
    expect(FormValidators.host("").error).toBe("请输入主机地址");
    expect(FormValidators.host(null).error).toBe("请输入主机地址");
  });

  it("port: optional, digits-only base-10, 1..65535 (Dart int.tryParse)", () => {
    expect(FormValidators.port(null).error).toBeNull();
    expect(FormValidators.port("").error).toBeNull();
    expect(FormValidators.port("22").error).toBeNull();
    expect(FormValidators.port("0").error).toBe("端口号必须是 1-65535");
    expect(FormValidators.port("65536").error).toBe("端口号必须是 1-65535");
    expect(FormValidators.port("abc").error).toBe("端口号必须是 1-65535"); // not digits -> tryParse null
    expect(FormValidators.port("0x10").error).toBe("端口号必须是 1-65535"); // Dart tryParse is base-10 digits only
  });

  it("url: http(s):// + non-whitespace", () => {
    expect(FormValidators.url("https://example.com/a b").error).toBe("请输入有效的 URL"); // whitespace inside
    expect(FormValidators.url("https://example.com").error).toBeNull();
    expect(FormValidators.url("ftp://example.com").error).toBe("请输入有效的 URL");
    expect(FormValidators.url("").error).toBe("请输入 URL");
  });

  it("combine: first failing validator wins", () => {
    const r = FormValidators.combine([
      () => FormValidators.required("ok"),
      () => FormValidators.port("0"),
      () => FormValidators.required(""), // would fail but is not reached
    ]);
    expect(r.error).toBe("端口号必须是 1-65535");
    const allOk = FormValidators.combine([
      () => FormValidators.required("x"),
      () => FormValidators.port("22"),
    ]);
    expect(allOk.error).toBeNull();
  });
});
