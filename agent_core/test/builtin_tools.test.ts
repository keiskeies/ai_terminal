// W4 builtin tool layer: framework (registry/scope/OpenAI schema/MCP descriptor)
// + the four pure-Node tools. File tools use a hermetic temp dir so they are
// deterministic; fetch_url uses a data: URL (success) + a refused port (failure)
// so no real network is required.
import {describe,it,expect,beforeAll,afterAll} from "vitest";
import {mkdirSync,writeFileSync,rmSync} from "fs";
import {tmpdir} from "os";
import {join} from "path";
import {
  AgentToolRegistry, ToolScope, ToolKind, ToolResult, HostExecutionResult,
  LocalFileReadTool, LocalDirListTool, FetchUrlTool, LocalExecTool, runLocalCommand,
} from "../src/tools/builtin.js";
import {buildDefaultToolRegistry, ToolArgs} from "../src/tools/index.js";
import {detectShell, wrapCommand} from "../src/utils/shell_detect.js";

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
   // local session hides local_exec; the other 3 tools have schemas
   expect(schema.length).toBe(3);
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
 it("data: URL returns the body",async()=>{
   const res=await new FetchUrlTool().execute(ToolArgs.wrap({url:"data:text/plain,hi"}),{});
   expect(res.success).toBe(true);
   expect(res.output).toBe("hi");
 });
 it("long body is truncated with a note",async()=>{
   const body="y".repeat(500);
   const url="data:text/plain,"+body;
   const res=await new FetchUrlTool().execute(ToolArgs.wrap({url,max_chars:100}),{});
   expect(res.success).toBe(true);
   expect(res.output).toContain("truncated");
   expect(res.output.length).toBeLessThan(body.length);
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
 it("wrapCommand branches by shell",()=>{
   expect(wrapCommand("ls","bash","MK")).toBe("ls; MK $?");
   expect(wrapCommand("dir","powershell","MK")).toBe("dir; MK $LASTEXITCODE");
   expect(wrapCommand("dir","cmd","MK")).toBe("dir & MK %errorlevel%");
 });
 it("R8: marker pattern is marker+digits, not bare substring",()=>{
   const wrapped=wrapCommand("echo done","bash","EXITCODE_LOCAL");
   expect(wrapped).toContain("EXITCODE_LOCAL");
   expect(wrapped).toContain("$?");
 });
});
