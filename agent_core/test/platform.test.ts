// W8 platform tool-subset tests — hermetic.
import {describe,it,expect} from "vitest";
import {buildDefaultToolRegistry} from "../src/tools/index.js";
import {MOBILE_SAFE_TOOLS, DESKTOP_ONLY_TOOLS, toolsForPlatform} from "../src/tools/platform.js";

describe("toolsForPlatform", () => {
  it("mobile returns only the MOBILE_SAFE_TOOLS subset", () => {
    const all = ["local_file_read","local_file_write","fetch_url","web_search","local_exec","local_dir_list"];
    const mobile = toolsForPlatform("mobile", all);
    expect(mobile).toContain("local_file_read");
    expect(mobile).toContain("fetch_url");
    expect(mobile).toContain("web_search");
    expect(mobile).not.toContain("local_file_write");
    expect(mobile).not.toContain("local_exec");
  });

  it("desktop returns all tools unchanged", () => {
    const all = ["local_file_read","local_file_write","fetch_url","local_exec"];
    expect(toolsForPlatform("desktop", all)).toEqual(all);
  });

  it("empty input returns empty array for both platforms", () => {
    expect(toolsForPlatform("mobile", [])).toEqual([]);
    expect(toolsForPlatform("desktop", [])).toEqual([]);
  });
});

describe("MOBILE_SAFE_TOOLS + DESKTOP_ONLY_TOOLS", () => {
  it("the two sets are disjoint (no tool is both mobile-safe and desktop-only)", () => {
    for (const t of MOBILE_SAFE_TOOLS) {
      expect(DESKTOP_ONLY_TOOLS.has(t)).toBe(false);
    }
  });

  it("local_file_write and local_exec are desktop-only", () => {
    expect(DESKTOP_ONLY_TOOLS.has("local_file_write")).toBe(true);
    expect(DESKTOP_ONLY_TOOLS.has("local_exec")).toBe(true);
    expect(MOBILE_SAFE_TOOLS.has("local_file_write")).toBe(false);
    expect(MOBILE_SAFE_TOOLS.has("local_exec")).toBe(false);
  });
});

describe("buildDefaultToolRegistry(platform)", () => {
  it("desktop (default) includes all 10 tools", () => {
    const reg = buildDefaultToolRegistry();
    const names = reg.all.map((t) => t.name);
    expect(names).toContain("local_file_read");
    expect(names).toContain("local_file_write");
    expect(names).toContain("fetch_url");
    expect(names).toContain("local_exec");
    expect(names.length).toBe(10);
  });

  it("mobile excludes write/patch/move/delete/local_exec", () => {
    const reg = buildDefaultToolRegistry("mobile");
    const names = reg.all.map((t) => t.name);
    expect(names).toContain("local_file_read");
    expect(names).toContain("fetch_url");
    expect(names).toContain("web_search");
    expect(names).not.toContain("local_file_write");
    expect(names).not.toContain("local_file_patch");
    expect(names).not.toContain("local_file_move");
    expect(names).not.toContain("local_file_delete");
    expect(names).not.toContain("local_exec");
    // Only the 5 mobile-safe tools should be present
    expect(names.length).toBe(5);
  });

  it("mobile registry tools are all in MOBILE_SAFE_TOOLS", () => {
    const reg = buildDefaultToolRegistry("mobile");
    for (const t of reg.all) {
      expect(MOBILE_SAFE_TOOLS.has(t.name)).toBe(true);
    }
  });
});
