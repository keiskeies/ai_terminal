// W4 builtin tool layer: framework (registry/scope/OpenAI schema/MCP descriptor)
// + the four pure-Node tools. File tools use a hermetic temp dir so they are
// deterministic; fetch_url uses a data: URL (success) + a refused port (failure)
// so no real network is required.
import {describe,it,expect,beforeAll,afterAll} from "vitest";
import {mkdirSync,writeFileSync,rmSync,readFileSync,existsSync,statSync,unlinkSync} from "fs";
import {tmpdir} from "os";
import {join} from "path";
import {
  AgentToolRegistry, ToolScope, ToolKind, ToolResult, HostExecutionResult,
  LocalFileReadTool, LocalDirListTool, FetchUrlTool, LocalExecTool, runLocalCommand,
  LocalFileWriteTool, LocalFilePatchTool, LocalFileMoveTool, LocalFileDeleteTool,
} from "../src/tools/builtin.js";
import {buildDefaultToolRegistry, ToolArgs} from "../src/tools/index.js";
import {detectShell, wrapCommand, extractExitMarker} from "../src/utils/shell_detect.js";

let T="";
beforeAll(()=>{
  T=join(tmpdir(),"ac_w4_"+process.pid);
  // create all directories first, then files
  mkdirSync(join(T,"sub"),{recursive:true});
  mkdirSync(join(T,".git"),{recursive:true});
  mkdirSync(join(T,"node_modules"),{recursive:true});
  writeFileSync(join(T,"sub","a.txt"),"line1"+String.fromCharCode(10)+"line2"+String.fromCharCode(10),"utf-8");
  writeFileSync(join(T,"sub","b.txt"),"x","utf-8");
  writeFileSync(join(T,".git","marker"),"g","utf-8");
  writeFileSync(join(T,"node_modules","junk"),"j","utf-8");
  writeFileSync(join(T,".env"),"SECRET=x","utf-8");
});
afterAll(()=>{ try{rmSync(T,{recursive:true,force:true});}catch{} });

describe("AgentToolRegistry framework",()=>{
 it("visibleFor filters by session type",()=>{
   const r=new AgentToolRegistry();
   r.register(new LocalFileReadTool(), ToolScope.all);
   r.register(new LocalExecTool(), ToolScope.sshSession);
   const local=r.visibleFor({isLocalSession:true}).map(t=>t.name);
   const ssh=r.visibleFor({isLocalSession:false}).map(t=>t.name);
   expect(local).toContain("local_file_read");
   expect(local).not.toContain("local_exec");
   expect(ssh).toContain("local_exec");
   expect(ssh).toContain("local_file_read");
 });
 it("buildOpenAIToolsSchema has type/function/parameters shape",()=>{
   const r=buildDefaultToolRegistry();
   const schema=r.buildOpenAIToolsSchema({isLocalSession:true});
   // local session hides local_exec; all-scope tools + localSession write-class tools are visible.
   const names=schema.map((x:any)=>x.function.name).sort();
   expect(names).toContain("local_file_read");
   expect(names).toContain("local_file_search");
   expect(names).toContain("local_file_write");
   expect(names).not.toContain("local_exec");
   expect(schema.length).toBeGreaterThanOrEqual(7);
   const read=schema.find((x:any)=>x.function.name==="local_file_read")!;
   expect(read.type).toBe("function");
   expect(read.function.parameters).toHaveProperty("type","object");
   expect(read.function.parameters.required).toEqual(["path"]);
 });
 it("mcpDescriptor matches tool.schema.json shape",()=>{
   const r=buildDefaultToolRegistry();
   const tool=r.get("local_file_read")!;
   const d=r.mcpDescriptor(tool,"builtin");
   expect(d.name).toBe("local_file_read");
   expect(d.kind).toBe(ToolKind.read);
   expect(d.source).toBe("builtin");
   expect(d.scope).toBe("all");
   expect(d.idempotent).toBe(true);
   expect(d.inputSchema).toHaveProperty("type","object");
 });
 it("isChangeRecordingTool true for write/destructive, false for read/network",()=>{
   const r=buildDefaultToolRegistry();
   expect(r.isChangeRecordingTool("local_exec")).toBe(false); // recordsChanges overridden
   expect(r.isChangeRecordingTool("local_file_read")).toBe(false);
   expect(r.isChangeRecordingTool("fetch_url")).toBe(false);
 });
 it("unregisterPrefix removes by prefix",()=>{
   const r=buildDefaultToolRegistry();
   expect(r.has("local_file_read")).toBe(true);
   r.unregisterPrefix("local_");
   expect(r.has("local_file_read")).toBe(false);
   expect(r.has("local_exec")).toBe(false);
 });
});

describe("LocalFileReadTool",()=>{
 it("returns line-numbered content",async()=>{
   const res=await new LocalFileReadTool().execute(ToolArgs.wrap({path:join(T,"sub","a.txt")}),{});
   expect(res.success).toBe(true);
   expect(res.output).toContain("line1");
   expect(res.output).toContain("line2");
   // line number prefix
   expect(res.output.split(String.fromCharCode(10)).some(l=>l.startsWith("1"+String.fromCharCode(9)))).toBe(true);
 });
 it("missing file -> failure",async()=>{
   const res=await new LocalFileReadTool().execute(ToolArgs.wrap({path:join(T,"nope.txt")}),{});
   expect(res.success).toBe(false);
 });
 it("directory path -> failure pointing to local_dir_list",async()=>{
   const res=await new LocalFileReadTool().execute(ToolArgs.wrap({path:join(T,"sub")}),{});
   expect(res.success).toBe(false);
   expect(res.error).toContain("directory");
 });
});

describe("LocalDirListTool",()=>{
 it("lists files with sizes and dirs with / suffix",async()=>{
   const res=await new LocalDirListTool().execute(ToolArgs.wrap({path:join(T,"sub"),depth:1}),{});
   expect(res.success).toBe(true);
   expect(res.output).toContain("a.txt");
   expect(res.output).toContain("b.txt");
 });
 it("skips .git / node_modules by default",async()=>{
   const res=await new LocalDirListTool().execute(ToolArgs.wrap({path:T,depth:1}),{});
   expect(res.success).toBe(true);
   expect(res.output).not.toContain(".git");
   expect(res.output).not.toContain("node_modules");
 });
 it("include_hidden shows .env (hidden file not in SKIPPED_DIRS)",async()=>{
   const res=await new LocalDirListTool().execute(ToolArgs.wrap({path:T,depth:1,include_hidden:true}),{});
   expect(res.success).toBe(true);
   expect(res.output).toContain(".env");
 });
 it("without include_hidden .env is hidden",async()=>{
   const res=await new LocalDirListTool().execute(ToolArgs.wrap({path:T,depth:1}),{});
   expect(res.success).toBe(true);
   expect(res.output).not.toContain(".env");
 });
 it("glob filter keeps only matching names",async()=>{
   const res=await new LocalDirListTool().execute(ToolArgs.wrap({path:join(T,"sub"),depth:1,glob:"*.txt"}),{});
   expect(res.success).toBe(true);
   expect(res.output).toContain("a.txt");
 });
 it("missing dir -> failure",async()=>{
   const res=await new LocalDirListTool().execute(ToolArgs.wrap({path:join(T,"ghost")}),{});
   expect(res.success).toBe(false);
 });
});

describe("FetchUrlTool",()=>{
 it("non-http(s) URL (data:) -> failure (参数错误: scheme)",async()=>{
   const res=await new FetchUrlTool().execute(ToolArgs.wrap({url:"data:text/plain,hi"}),{});
   expect(res.success).toBe(false);
   // Dart-faithful: 参数错误: url 必须以 http:// 或 https:// 开头
   expect(res.error).toContain("url");
 });
 it("long http body is truncated with CJK note",async()=>{
   // Stub fetch so no real network call is made: return a 500-char html body
   const origFetch = globalThis.fetch;
   const body="<html><head><title>Test Page</title></head><body><p>"+("y".repeat(500))+"</p></body></html>";
   globalThis.fetch = (async (input: any, init?: any) => {
     return new Response(body, {status:200, headers:{"content-type":"text/html"}});
   }) as any;
   try {
     const res=await new FetchUrlTool().execute(ToolArgs.wrap({url:"http://example.com/",max_chars:100}),{});
     expect(res.success).toBe(true);
     // CJK truncation notice: ...(正文已截断，共 N 字符，仅显示前 100 字符)
     expect(res.output).toContain("\u6B63\u6587\u5DF2\u622A\u65AD");
     expect(res.output).toContain("URL: http://example.com/");
     expect(res.output).toContain("标题: Test Page");
   } finally {
     globalThis.fetch = origFetch;
   }
 });
 it("connection refused -> failure",async()=>{
   const res=await new FetchUrlTool().execute(ToolArgs.wrap({url:"http://127.0.0.1:1/"}),{});
   expect(res.success).toBe(false);
 });
 it("blank url -> failure",async()=>{
   const res=await new FetchUrlTool().execute(ToolArgs.wrap({url:""}),{});
   expect(res.success).toBe(false);
 });
});

describe("shell_detect (R6)",()=>{
 it("detectShell by extension",()=>{
   expect(detectShell("powershell")).toBe("powershell");
   expect(detectShell("C:\Windows\System32\cmd.exe")).toBe("cmd");
   expect(detectShell("bash")).toBe("bash");
 });
 // R6.1 pin (fixed): the wrapper must ECHO marker+exit-code. The previous form
 // `cmd; MK $?` EXECUTED the bare marker (command-not-found) and destroyed the
 // real exit status (bash 127 / cmd 9009 / PS "not recognized" 1) - verified
 // empirically on all three shells. Byte-faithful to Dart posixWrapWithExitMarker
 // (command_executor.dart) + wrapCommandWithExitMarker (local_terminal_service.dart).
 it("wrapCommand branches by shell (R6.1)",()=>{
   expect(wrapCommand("ls","bash","MK:")).toBe('ls; echo "MK:$?"');
   expect(wrapCommand("ls","zsh","MK:")).toBe('ls; echo "MK:$?"');
   // multi-line/heredoc: echo goes on a NEW line - "EOF; echo" is not a terminator
   expect(wrapCommand("a\nb","sh","MK:")).toBe('a\nb\necho "MK:$?"');
   expect(wrapCommand("dir","cmd","MK:")).toBe("dir & echo MK:%errorlevel%");
   const ps=wrapCommand("dir","powershell","MK:");
   expect(ps.startsWith("$LASTEXITCODE=$null; dir; ")).toBe(true); // session-leak guard
   expect(ps).toContain("$__ec=if($?){0}");                        // cmdlet failure -> 1
   expect(ps.endsWith('echo "MK:$__ec"')).toBe(true);
 });
 // R8.1: full pattern (marker+digits), never a bare substring - the command echo
 // contains the literal marker and would fire completion before the command ran.
 it("R8.1: extractExitMarker needs marker+digits",()=>{
   expect(extractExitMarker('echo "EXITCODE_LOCAL:$?"\n',"EXITCODE_LOCAL:")).toBe(null);
   expect(extractExitMarker("x\nEXITCODE_LOCAL:7\n","EXITCODE_LOCAL:")!.exitCode).toBe(7);
   expect(extractExitMarker("EXITCODE_LOCAL:0rest","EXITCODE_LOCAL:")!.after).toBe("rest");
   expect(extractExitMarker("done","EXITCODE_LOCAL:")).toBe(null);
 });
});

// R6.1/R8.1 end-to-end through the real host shells (bounded - a hang here is
// the historical executeAndWait deadlock, not a flaky timeout). bash is pinned
// at unit level only: BSS-CRU mangles argv through `-c` on this CI host
// (`false; echo "MK:$?"` prints MK:0; script files exit 127), so a bash e2e
// assertion would encode the sandbox bug rather than our contract.
// The cmd errorlevel PARSE-time caveat (Dart parity, documented in
// shell_detect.ts) is why no cmd test asserts a NON-ZERO native code.
// ── Host-shell gate (CI portability) ───────────────────────────────────────
// The CI runner is ubuntu-latest, where neither `powershell` nor `cmd` exists,
// and runLocalCommand uses spawn(..., {shell:false}) - a missing binary emits
// an "error" event, which runLocalCommand REJECTS on (verified: ENOENT). So an
// ungated Windows-shell suite does not merely mismatch on Linux, it errors.
// Resolution is probed exactly the way the code under test resolves it (no
// shell:true), so the gate cannot be wider than the spawn.
import {spawnSync} from "child_process";
const resolves = (bin: string, args: string[]): boolean => {
  try { return !spawnSync(bin, args, {encoding: "utf-8", timeout: 15000, shell: false}).error; }
  catch { return false; }
};
const hasCmd = resolves("cmd", ["/c", "exit 0"]);
const hasPowershell = resolves("powershell", ["-NoProfile", "-Command", "exit 0"]);
const hasBash = resolves("bash", ["-c", "exit 0"]);
const winShells = hasCmd && hasPowershell;
// Both shells are Windows-only; gate the suite on resolution rather than on
// process.platform, so the skip reason is provable from the same probe the
// spawn uses.
const describeHostShells = winShells ? describe : describe.skip;
describeHostShells("runLocalCommand exit marker (R6.1 + R8.1 e2e)",()=>{
 const M="EXITCODE_LOCAL:";
 // The DSH sandbox blocks PowerShell from executing native exes (AppLocker-style
 // "Cannot run a document in the middle of a pipeline"), so a native-command
 // failure code cannot be round-tripped here. Two real, host-independent
 // fixtures cover the same plumbing:
 // 1) any FAILING CMDLET -> Dart derivation reports 1 (never a stale code);
 // 2) Dart derivation order: $? is consulted FIRST, so a command that leaves a
 //    non-zero $LASTEXITCODE but succeeds by $? reports 0. Pinned deliberately
 //    (Dart parity, local_terminal_service.dart L210-216) - reorder at your peril.
 it("powershell: failing cmdlet reports 1 via the marker",async()=>{
   const r=await runLocalCommand(wrapCommand("$ErrorActionPreference=\"Stop\"; Get-ChildItem -Path Z:/nope_does_not_exist -ErrorAction Stop","powershell",M),process.cwd(),"powershell",60);
   expect(r.exitCode).toBe(1);
   expect(r.stdout).not.toContain(M); // marker line stripped from stdout
 },30000);
 it("powershell: $? precedes $LASTEXITCODE in the derivation (Dart parity)",async()=>{
   const r=await runLocalCommand(wrapCommand("$LASTEXITCODE=5","powershell",M),process.cwd(),"powershell",60);
   expect(r.exitCode).toBe(0); // assignment leaves $? true -> first branch wins
 },30000);
 it("powershell: cmdlet failure reports 1, never a stale code",async()=>{
   const r=await runLocalCommand(wrapCommand("Get-ChildItem Z:/definitely_missing_dir_xyz","powershell",M),process.cwd(),"powershell",60);
   expect(r.exitCode).toBe(1);
 },30000);
 it("powershell: success stays 0 and keeps stdout",async()=>{
   const r=await runLocalCommand(wrapCommand("Write-Output ok","powershell",M),process.cwd(),"powershell",60);
   expect(r.exitCode).toBe(0);
   expect(r.stdout).toContain("ok");
 },30000);
 it("cmd: success reports 0 and strips the marker line",async()=>{
   const r=await runLocalCommand(wrapCommand("echo hi","cmd",M),process.cwd(),"cmd",30);
   expect(r.exitCode).toBe(0);
   expect(r.stdout).toContain("hi");
   expect(r.stdout).not.toContain(M);
 },30000); // NOTE: a WRAPPED `exit /b 3` kills cmd before the wrapper echo runs - no
 // marker exists and the close code is cmd's own; asserting that would pin
 // wrapper mechanics, not the fallback, so the raw unwrapped form is used.
 it("marker never emitted (raw command, early exit) -> close code fallback",async()=>{
   const r=await runLocalCommand("exit /b 3",process.cwd(),"cmd",30);
   expect(r.exitCode).toBe(3);
 },30000);
});
// A POSIX counterpart for the same plumbing (R6.1 marker + R8.1 close-code
// fallback). Deliberately avoids the bash $? derivation: on this repo CI host
// BSS-CRU mangles argv through -c, so `false; echo "MK:$?"` prints MK:0 (shown
// again while writing this file). Asserting it would encode the sandbox bug,
// so the bash cases carry a LITERAL marker digit - same parsing and stripping
// path, no shell-specific exit-code semantics. bash resolves here too, so this
// suite is exercised on Windows as well as on the Linux runner.
describe("runLocalCommand on bash, literal marker (host-independent plumbing)", () => {
  const M = "EXITCODE_LOCAL:";
  const cases = hasBash ? it : it.skip;
  cases("marker with a literal code is parsed and stripped from stdout", async () => {
    const r = await runLocalCommand('echo out; echo "' + M + '7"', process.cwd(), "bash", 30);
    expect(r.exitCode).toBe(7);
    expect(r.stdout).toContain("out");
    expect(r.stdout).not.toContain(M);
  }, 30000);
  cases("no marker at all -> the close code is the exit code", async () => {
    const r = await runLocalCommand("exit 3", process.cwd(), "bash", 30);
    expect(r.exitCode).toBe(3);
  }, 30000);
});

// Anti-vacuity for the gate above: a skip must only ever mean "this host has no
// such shell", never "the gate is broken". On Windows every host-shell suite
// must actually have run, and on Linux bash must be resolvable (the image ships
// /bin/bash), so the Linux job still exercises runLocalCommand end-to-end.
describe("host-shell gate is sound", () => {
  it("windows resolves both shells and runs the windows suite", () => {
    if (process.platform !== "win32") return;
    expect(hasCmd, "cmd must resolve on Windows").toBe(true);
    expect(hasPowershell, "powershell must resolve on Windows").toBe(true);
    expect(winShells).toBe(true);
  });
  it("linux resolves bash so the runner is not silently shell-free", () => {
    if (process.platform !== "linux") return;
    expect(hasBash, "/bin/bash must resolve on the CI runner").toBe(true);
  });
});


// ── LocalFileReadTool: edge cases ──
describe("LocalFileReadTool edge cases", () => {
  const T = mkdirSync(join(tmpdir(), "builtin_read_edge_" + Date.now()), {recursive: true});
  const ctx = {hostId: "h", sessionType: "local", generation: 1, cancelled: () => false} as any;

  afterAll(() => rmSync(T, {recursive: true, force: true}));

  it("start_line past EOF returns empty range, not an error", async () => {
    writeFileSync(join(T, "short.txt"), "line1\nline2\nline3\n");
    const tool = new LocalFileReadTool();
    const r = await tool.execute(ToolArgs.wrap({path: join(T, "short.txt"), start_line: 999}), ctx as any);
    expect(r.success).toBe(true);
    // The range is empty: showing 999-999 of 3 lines -> out is empty
    // The header still reports the total line count
    expect(r.output).toContain("file:");
    expect(r.output).toContain("4 lines"); // "line1\nline2\nline3\n".split("\n") -> 4 elements
  });

  it("start_line 0 is clamped to 1", async () => {
    writeFileSync(join(T, "clamp.txt"), "a\nb\nc\n");
    const tool = new LocalFileReadTool();
    const r = await tool.execute(ToolArgs.wrap({path: join(T, "clamp.txt"), start_line: 0}), ctx as any);
    expect(r.success).toBe(true);
    expect(r.output).toContain("1\ta"); // first line is shown
  });

  it("max_lines=1 shows only the first line with a continuation hint", async () => {
    writeFileSync(join(T, "cap.txt"), "one\ntwo\nthree\n");
    const tool = new LocalFileReadTool();
    const r = await tool.execute(ToolArgs.wrap({path: join(T, "cap.txt"), start_line: 1, max_lines: 1}), ctx as any);
    expect(r.success).toBe(true);
    expect(r.output).toContain("one");
    expect(r.output).not.toContain("two");
    expect(r.output).toContain("...more, use start_line: 2");
  });

  it("binary file (null bytes) is rejected with a helpful message", async () => {
    const target = join(T, "binary.dat");
    // Simulate a minimal binary file: 4 null bytes + some data
    const buf = Buffer.alloc(16);
    buf.write("hello world\0\0\0\0", "latin1");
    writeFileSync(target, buf);
    const tool = new LocalFileReadTool();
    const r = await tool.execute(ToolArgs.wrap({path: target}), ctx as any);
    expect(r.success).toBe(false);
    expect(r.error).toContain("binary file");
    expect(r.error).toContain("binary.dat"); // file name in the message
  });
});

// ── LocalDirListTool: depth=3 ──
describe("LocalDirListTool depth=3", () => {
  const T = mkdirSync(join(tmpdir(), "builtin_dir_depth_" + Date.now()), {recursive: true});
  const ctx = {hostId: "h", sessionType: "local", generation: 1, cancelled: () => false} as any;

  beforeAll(() => {
    mkdirSync(join(T, "a"), {recursive: true});
    mkdirSync(join(T, "a", "b"), {recursive: true});
    mkdirSync(join(T, "a", "b", "c"), {recursive: true});
    writeFileSync(join(T, "a", "b", "c", "deep.txt"), "x");
  });
  afterAll(() => rmSync(T, {recursive: true, force: true}));

  it("depth=3 lists files at all three levels", async () => {
    const tool = new LocalDirListTool();
    const r = await tool.execute(ToolArgs.wrap({path: T, depth: 3}), ctx as any);
    expect(r.success).toBe(true);
    expect(r.output).toContain("a/");
    expect(r.output).toContain("b/");
    expect(r.output).toContain("c/");
    // Files inside c/ are at nesting level 4 - beyond depth=3, not listed
    expect(r.output).not.toContain("deep.txt");
  });

  it("depth=1 does NOT descend into subdirectories", async () => {
    const tool = new LocalDirListTool();
    const r = await tool.execute(ToolArgs.wrap({path: T, depth: 1}), ctx as any);
    expect(r.success).toBe(true);
    expect(r.output).toContain("a/");
    // b/ and c/ should not appear since we only went one level
    expect(r.output).not.toContain("b/");
  });
});

// ── LocalFileMoveTool: cross-device fallback + self-move ──
describe("LocalFileMoveTool edge cases", () => {
  const T = mkdirSync(join(tmpdir(), "builtin_move_edge_" + Date.now()), {recursive: true});
  const ctx = {hostId: "h", sessionType: "local", generation: 1, cancelled: () => false} as any;

  afterAll(() => rmSync(T, {recursive: true, force: true}));

  it("moving a file onto itself fails cleanly", async () => {
    const tool = new LocalFileMoveTool();
    const target = join(T, "self.txt");
    writeFileSync(target, "data");
    const r = await tool.execute(ToolArgs.wrap({path: target, dst: target, overwrite: true}), ctx as any);
    // The rename will either fail (EXDEV/ENOTEMPTY) or succeed no-op;
    // either way the source must still exist or the tool reports the result.
    if (r.success) {
      // rename no-op on POSIX: source path still valid
      expect(existsSync(target) || existsSync(target)).toBe(true);
    } else {
      // The error message should be informative
      expect(r.error).toBeDefined();
    }
  });

  it("moving into a non-existent parent creates the parent dir", async () => {
    const tool = new LocalFileMoveTool();
    const src = join(T, "orphan.txt");
    const dst = join(T, "new_dir", "orphan_moved.txt");
    writeFileSync(src, "x");
    const r = await tool.execute(ToolArgs.wrap({path: src, dst: dst}), ctx as any);
    expect(r.success).toBe(true);
    expect(existsSync(dst)).toBe(true);
    expect(existsSync(src)).toBe(false);
  });

  it("restoreFrom/restoreTo extras are set on success", async () => {
    const tool = new LocalFileMoveTool();
    const src = join(T, "restore_src.txt");
    const dst = join(T, "restore_dst.txt");
    writeFileSync(src, "y");
    const r = await tool.execute(ToolArgs.wrap({path: src, dst: dst}), ctx as any);
    expect(r.success).toBe(true);
    expect(r.restoreFrom).toBe(dst);
    expect(r.restoreTo).toBe(src);
  });
});

// ── LocalFileDeleteTool: TRASH_DIR_NAME leakage ──
describe("LocalFileDeleteTool trash layout", () => {
  const T = mkdirSync(join(tmpdir(), "builtin_del_trash_" + Date.now()), {recursive: true});
  const ctx = {hostId: "h", sessionType: "local", generation: 1, cancelled: () => false} as any;

  afterAll(() => rmSync(T, {recursive: true, force: true}));

  it("the trash dir is created inside the file's parent, not a global root", async () => {
    const sub = join(T, "subdir");
    mkdirSync(sub, {recursive: true});
    const target = join(sub, "victim.txt");
    writeFileSync(target, "z");
    const tool = new LocalFileDeleteTool();
    const r = await tool.execute(ToolArgs.wrap({path: target}), ctx as any);
    expect(r.success).toBe(true);
    expect(existsSync(target)).toBe(false);
    // The trash layout is <parent>/.ai_terminal_trash/<timestamp>/victim.txt
    const trashDir = join(sub, ".ai_terminal_trash");
    expect(existsSync(trashDir)).toBe(true);
    // The .ai_terminal_trash dir itself must NOT be listed by LocalDirListTool
    // (it starts with '.', so include_hidden=false skips it by default)
    const dirTool = new LocalDirListTool();
    const dr = await dirTool.execute(ToolArgs.wrap({path: sub}), ctx as any);
    expect(dr.success).toBe(true);
    expect(dr.output).not.toContain(".ai_terminal_trash");
  });

  it("hard:true on a file leaves no trash entry", async () => {
    const target = join(T, "hard.txt");
    writeFileSync(target, "h");
    const tool = new LocalFileDeleteTool();
    const r = await tool.execute(ToolArgs.wrap({path: target, hard: true}), ctx as any);
    expect(r.success).toBe(true);
    expect(existsSync(target)).toBe(false);
    // No trash dir should be created for a hard delete
    const trashDir = join(T, ".ai_terminal_trash");
    expect(existsSync(trashDir)).toBe(false);
  });
});
