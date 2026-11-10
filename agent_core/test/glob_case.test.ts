// glob_case.test.ts - the glob helper must stay ONE implementation carrying
// Dart's case polarity.
//
// Historical defect found in this port: two independent glob->RegExp copies lived
// in src/tools/builtin.ts. The local_dir_list copy was case-sensitive on every
// OS; the local_file_search copy inverted the flag (case-sensitive on Windows,
// insensitive on Linux/macOS). Both tools therefore filtered the *same* pattern
// differently depending on which one ran, and the search copy disagreed with Dart
// on both platform families. Nothing failed loudly: a filter that drops or keeps
// an extra file only changes the length of a listing.
//
// Dart reference (ai_terminal/lib/services/local_file_tools.dart:278 and :353,
// byte-identical expressions):
//   RegExp('^$escaped$', caseSensitive: !Platform.isWindows)
// i.e. case-INSENSITIVE matching on Windows (NTFS lookups are case-insensitive)
// and case-SENSITIVE on Linux/macOS.
//
// The polarity assertion below never touches the host filesystem's case rules: it
// evaluates the extracted flags expression against fake process objects, so it
// reads the same on Windows, macOS and Linux.
//
// Not a 6.2 rule and not listed in the 6.3 table; same standing as
// manifest.test.ts / build_externals.test.ts - it guards a port-specific defect.
import {describe, it, expect, beforeAll, afterAll} from "vitest";
import {readFileSync, writeFileSync, mkdirSync, rmSync} from "fs";
import {tmpdir} from "os";
import {join} from "path";
import {LocalDirListTool, LocalFileSearchTool} from "../src/tools/builtin.js";
import {ToolArgs} from "../src/tools/tool_args.js";

const SRC = readFileSync(new URL("../src/tools/builtin.ts", import.meta.url), "utf-8");
const FLAGS_AT = /return new RegExp\("\^" \+ re \+ "\$", ([^)]*)\);/;

describe("glob helper is a single implementation", () => {
  it("exactly one globToRegExp definition exists", () => {
    expect(SRC.split("function globToRegExp(").length - 1).toBe(1);
  });
  it("no second glob matcher hides as a class member", () => {
    // globToRe( / globToRegex( / toGlobRe( - anything but the one helper name
    expect(/globToRe(?!gExp)[A-Za-z0-9_]*\s*\(/.test(SRC)).toBe(false);
  });
  it("the single RegExp construction takes a flags expression", () => {
    expect(FLAGS_AT.test(SRC)).toBe(true);
  });
});

describe("case polarity matches Dart caseSensitive !isWindows", () => {
  const m = SRC.match(FLAGS_AT);
  if (!m) throw new Error("flags expression not found in builtin.ts - did the glob helper change shape?");
  const flagsFor = (platform: string): string | undefined =>
    new Function("process", "return (" + m[1] + ")")({platform}) as string | undefined;

  it("Windows: pattern is case-insensitive via the i flag", () => {
    expect(flagsFor("win32")).toBe("i");
  });
  it("linux and darwin: pattern is case-sensitive (no flag)", () => {
    expect(flagsFor("linux")).toBeUndefined();
    expect(flagsFor("darwin")).toBeUndefined();
  });
  it("exactly one branch of four platform values carries a flag", () => {
    // Guards against a sideways drift such as "i" on both sides or "ig" added.
    const flags = ["win32", "linux", "darwin", "freebsd"].map(flagsFor);
    expect(flags.filter((f) => f === "i").length).toBe(1);
    expect(flags.filter((f) => f === undefined).length).toBe(3);
  });
});

describe("both tools filter the same way (the drift this guards)", () => {
  let T = "";
  beforeAll(() => {
    T = join(tmpdir(), "ac_glob_case_" + process.pid);
    rmSync(T, {recursive: true, force: true});
    mkdirSync(T, {recursive: true});
    writeFileSync(join(T, "a.txt"), "needle\n");
  });
  afterAll(() => rmSync(T, {recursive: true, force: true}));

  const dirList = async (glob: string | string[]): Promise<string> => {
    const r = await new LocalDirListTool().execute(ToolArgs.wrap({path: T, depth: 1, glob: glob}), {});
    expect(r.success).toBe(true, "dir_list failed: " + r.error);
    return r.output ?? "";
  };
  const search = async (glob: string | string[]): Promise<string> => {
    const r = await new LocalFileSearchTool().execute(ToolArgs.wrap({path: T, query: "needle", glob: glob}), {});
    expect(r.success).toBe(true, "file_search failed: " + r.error);
    return r.output ?? "";
  };
  const listed = (out: string): boolean => out.split(/\r?\n/).some((l) => l.trim().startsWith("a.txt"));
  const searched = (out: string): boolean => out.split(/\r?\n/).some((l) => l.trim().startsWith("a.txt:1:"));

  it("control: exact-case glob matches a.txt in both tools", async () => {
    expect(listed(await dirList("*.txt"))).toBe(true);
    expect(searched(await search("*.txt"))).toBe(true);
  }, 30000);

  it("a blank glob drops the pattern instead of filtering everything out", async () => {
    // Dart _globToRegExp: "if (glob.trim().isEmpty) return null;" - a blank
    // pattern is DISCARDED, so the caller is left with no filters and lists
    // everything. Drop the trim and " " compiles to /^ $/ instead, which matches
    // no file name: the same call now returns an empty listing. A space survives
    // ToolArgs.getStringList (it only drops zero-length strings), so this reaches
    // the helper intact and pins the trim itself.
    expect(listed(await dirList([" "]))).toBe(true);
    expect(searched(await search([" "]))).toBe(true);
    // a blank pattern mixed with a real one must not poison the real one
    expect(listed(await dirList([" ", "*.txt"]))).toBe(true);
    expect(searched(await search([" ", "*.txt"]))).toBe(true);
  }, 30000);
  it("a case-folded glob decides a.txt identically in both tools", async () => {
    expect(searched(await search("*.TXT"))).toBe(listed(await dirList("*.TXT")));
  }, 30000);

  it("the decision follows the platform rule, not the tool that ran", async () => {
    // Windows: the filesystem is case-insensitive, so "*.TXT" must still match
    //   a.txt - refusing it would hide real files from the model.
    // Case-sensitive filesystem: "*.TXT" must NOT match a.txt, or the filter
    //   silently admits names the caller never asked for.
    const expectMatch = process.platform === "win32";
    expect(listed(await dirList("*.TXT"))).toBe(expectMatch);
    expect(searched(await search("*.TXT"))).toBe(expectMatch);
  }, 30000);
});
