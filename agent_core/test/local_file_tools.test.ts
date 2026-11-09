// W4 local-file tool layer: hermetic tests for the 5 new pure-Node tools
// (search/write/patch/move/delete). File tools use a per-pid temp dir.
import {describe,it,expect,beforeAll,afterAll} from "vitest";
import {mkdirSync,writeFileSync,rmSync,readFileSync,existsSync,statSync,unlinkSync} from "fs";
import {tmpdir} from "os";
import {join} from "path";
import {
  LocalFileSearchTool, LocalFileWriteTool, LocalFilePatchTool,
  LocalFileMoveTool, LocalFileDeleteTool, ToolScope,
} from "../src/tools/builtin.js";
import {ToolArgs} from "../src/tools/tool_args.js";

let T="";
const ctx = {isLocalSession:true};
beforeAll(()=>{
  T = join(tmpdir(), "ac_w4_localfile_" + process.pid);
  rmSync(T, {recursive:true, force:true});
  mkdirSync(join(T,"sub"), {recursive:true});
  mkdirSync(join(T,".git"), {recursive:true});
  writeFileSync(join(T,"a.txt"), "alpha line\nbeta line\nneedle1\nneedle2\nneedle3\n");
  writeFileSync(join(T,"sub","b.txt"), "needle1\ngamma\nneedle2\n");
});
afterAll(()=>rmSync(T,{recursive:true,force:true}));

function args(obj: Record<string, unknown>): ToolArgs { return ToolArgs.wrap(obj); }
function ok(r: {success:boolean; output?:string; error?:string}): asserts r {
  expect(r.success).toBe(true, "expected success, got: " + r.error);
}

describe("local_file_search", () => {
  it("finds needle across multiple files in a dir", async () => {
    const tool = new LocalFileSearchTool();
    const r = await tool.execute(args({path:T, query:"needle"}), ctx as any);
    ok(r);
    expect(r.output).toContain("a.txt:3: needle1");
    expect(r.output).toContain("a.txt:4: needle2");
    expect(r.output).toContain("b.txt:1: needle1");
  });
  it("handles a missing path", async () => {
    const tool = new LocalFileSearchTool();
    const r = await tool.execute(args({path:join(T,"nope"), query:"x"}), ctx as any);
    expect(r.success).toBe(false);
  });
  it("handles empty query", async () => {
    const tool = new LocalFileSearchTool();
    const r = await tool.execute(args({path:T, query:""}), ctx as any);
    expect(r.success).toBe(false);
    expect(r.error).toContain("query");
  });
  it("filters by glob", async () => {
    const tool = new LocalFileSearchTool();
    const r = await tool.execute(args({path:T, query:"needle", glob:"*.txt"}), ctx as any);
    ok(r);
    expect(r.output).toContain("a.txt");
  });
});

describe("local_file_write", () => {
  it("writes new file and creates parent dir", async () => {
    const tool = new LocalFileWriteTool();
    const target = join(T,"sub","new","w.txt");
    const r = await tool.execute(args({path:target, content:"hello\nworld\n"}), ctx as any);
    ok(r);
    expect(readFileSync(target,"utf-8")).toBe("hello\nworld\n");
  });
  it("append mode appends to existing file", async () => {
    const tool = new LocalFileWriteTool();
    const target = join(T,"append.txt");
    writeFileSync(target,"first\n");
    const r = await tool.execute(args({path:target, content:"second\n", mode:"append"}), ctx as any);
    ok(r);
    expect(readFileSync(target,"utf-8")).toBe("first\nsecond\n");
  });
  it("write with content_b64 decodes base64", async () => {
    const tool = new LocalFileWriteTool();
    const target = join(T,"b64.txt");
    const r = await tool.execute(args({path:target, content_b64:Buffer.from("encoded\n").toString("base64")}), ctx as any);
    ok(r);
    expect(readFileSync(target,"utf-8")).toBe("encoded\n");
  });
  it("fails on unknown mode", async () => {
    const tool = new LocalFileWriteTool();
    const r = await tool.execute(args({path:join(T,"z.txt"), content:"x", mode:"zap"}), ctx as any);
    expect(r.success).toBe(false);
    expect(r.error).toContain("mode");
  });
  it("rejects content exceeding 8KB cap", async () => {
    const tool = new LocalFileWriteTool();
    const big = "A".repeat(9*1024);
    const r = await tool.execute(args({path:join(T,"big.txt"), content:big}), ctx as any);
    expect(r.success).toBe(false);
    expect(r.error).toContain("8192");
  });
});

describe("local_file_patch", () => {
  it("replaces unique old string", async () => {
    const tool = new LocalFilePatchTool();
    const target = join(T,"patch1.txt");
    writeFileSync(target,"before\nold_text\nafter\n");
    const r = await tool.execute(args({path:target, old:"old_text", new:"new_text"}), ctx as any);
    ok(r);
    expect(readFileSync(target,"utf-8")).toBe("before\nnew_text\nafter\n");
  });
  it("fails when old is ambiguous (appears more than once)", async () => {
    const tool = new LocalFilePatchTool();
    const target = join(T,"patch2.txt");
    writeFileSync(target,"dup\ndup\ndup\n");
    const r = await tool.execute(args({path:target, old:"dup", new:"x"}), ctx as any);
    expect(r.success).toBe(false);
  });
  it("reports diffAdditions/diffDeletions in extras", async () => {
    const tool = new LocalFilePatchTool();
    const target = join(T,"patch3.txt");
    writeFileSync(target,"line1\nline2\nline3\n");
    const r = await tool.execute(args({path:target, old:"line2", new:"A\nB"}), ctx as any);
    ok(r);
    // new has 2 lines replacing 1 → 1 addition, 0 deletions in LCS terms
    expect((r as any).diffAdditions).toBeDefined();
  });
});

describe("local_file_move", () => {
  it("moves a file to a new name in same dir", async () => {
    const tool = new LocalFileMoveTool();
    const src = join(T,"move_src.txt");
    writeFileSync(src,"payload");
    const dst = join(T,"move_dst.txt");
    const r = await tool.execute(args({path:src, dst}), ctx as any);
    ok(r);
    expect(existsSync(dst)).toBe(true);
    expect(existsSync(src)).toBe(false);
  });
  it("fails when dst exists without overwrite", async () => {
    const tool = new LocalFileMoveTool();
    writeFileSync(join(T,"o1.txt"),"a");
    writeFileSync(join(T,"o2.txt"),"b");
    const r = await tool.execute(args({path:join(T,"o1.txt"), dst:join(T,"o2.txt")}), ctx as any);
    expect(r.success).toBe(false);
    expect(r.error).toContain("overwrite");
  });
  it("overwrites when overwrite:true", async () => {
    const tool = new LocalFileMoveTool();
    writeFileSync(join(T,"ow1.txt"),"new");
    writeFileSync(join(T,"ow2.txt"),"old");
    const r = await tool.execute(args({path:join(T,"ow1.txt"), dst:join(T,"ow2.txt"), overwrite:true}), ctx as any);
    ok(r);
    expect(readFileSync(join(T,"ow2.txt"),"utf-8")).toBe("new");
  });
});

describe("local_file_delete", () => {
  it("moves a file into trash by default", async () => {
    const tool = new LocalFileDeleteTool();
    const target = join(T,"del1.txt");
    writeFileSync(target,"data");
    const r = await tool.execute(args({path:target}), ctx as any);
    ok(r);
    expect(existsSync(target)).toBe(false);
    // trash layout: <parent>/.ai_terminal_trash/<timestamp>/del1.txt
    const trashDir = join(T,".ai_terminal_trash");
    expect(existsSync(trashDir)).toBe(true);
  });
  it("hard:true permanently deletes", async () => {
    const tool = new LocalFileDeleteTool();
    const target = join(T,"hard1.txt");
    writeFileSync(target,"x");
    const r = await tool.execute(args({path:target, hard:true}), ctx as any);
    ok(r);
    expect(existsSync(target)).toBe(false);
  });
  it("fails on dir without recursive", async () => {
    const tool = new LocalFileDeleteTool();
    const dir = join(T,"del_dir");
    mkdirSync(dir,{recursive:true});
    const r = await tool.execute(args({path:dir}), ctx as any);
    expect(r.success).toBe(false);
    rmSync(dir,{recursive:true,force:true});
  });
  it("recursive:true trash-moves a dir", async () => {
    const tool = new LocalFileDeleteTool();
    const dir = join(T,"del_dir2");
    mkdirSync(dir,{recursive:true});
    writeFileSync(join(dir,"f.txt"),"y");
    const r = await tool.execute(args({path:dir, recursive:true}), ctx as any);
    ok(r);
    expect(existsSync(dir)).toBe(false);
  });
});

// ── R9 regression: full tool-pipeline (args parse → execute → result shape) ──
describe("regression: local-file tool pipeline", () => {
  it("write → read-back → patch → move → delete pipeline is coherent", async () => {
    const tool = new LocalFileWriteTool();
    const target = join(T,"pipeline.txt");

    // 1. write
    const w = await tool.execute(args({path:target, content:"one\ntwo\nthree\n"}), ctx as any);
    expect(w.success).toBe(true);

    // 2. patch
    const patcher = new LocalFilePatchTool();
    const p = await patcher.execute(args({path:target, old:"two", new:"TWO"}), ctx as any);
    expect(p.success).toBe(true);
    expect(readFileSync(target,"utf-8")).toBe("one\nTWO\nthree\n");

    // 3. move
    const mover = new LocalFileMoveTool();
    const moved = join(T,"pipeline_moved.txt");
    const m = await mover.execute(args({path:target, dst:moved}), ctx as any);
    expect(m.success).toBe(true);
    expect(existsSync(moved)).toBe(true);
    expect(existsSync(target)).toBe(false);

    // 4. delete (trash)
    const deleter = new LocalFileDeleteTool();
    const d = await deleter.execute(args({path:moved}), ctx as any);
    expect(d.success).toBe(true);
    expect(existsSync(moved)).toBe(false);
  });
});
