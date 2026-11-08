// tools/dispatcher.ts tests: registry lookup + R9 args parse + ToolResult->AgentEvent
// mapping + the dispatcher-level failure paths (unknown tool / cancelled / bad args).
import {describe,it,expect} from "vitest";
import {ToolDispatcher} from "../src/tools/dispatcher.js";
import {buildDefaultToolRegistry} from "../src/tools/index.js";
import {stableId} from "../src/utils/stable_hash.js";

const NL = String.fromCharCode(10);
const reg = () => buildDefaultToolRegistry();

describe("ToolDispatcher",()=>{
 it("unknown tool -> result event success=false, failureKind=unknown_tool", async()=>{
   const d=new ToolDispatcher(reg());
   const o=await d.dispatch({toolName:"nope", argsText:""});
   expect(o.executed).toBe(false);
   expect(o.event.type).toBe("result");
   expect(o.event.success).toBe(false);
   expect(o.event.failureKind).toBe("unknown_tool");
   expect(o.event.toolName).toBe("nope");
 });

 it("cancelled ctx short-circuits before execution", async()=>{
   const d=new ToolDispatcher(reg());
   const o=await d.dispatch({toolName:"fetch_url", argsText:"url: data:text/plain,hi", ctx:{cancelled:()=>true}});
   expect(o.executed).toBe(false);
   expect(o.event.success).toBe(false);
   expect(o.event.failureKind).toBe("cancelled");
 });

 it("fetch_url via free-text args (R9) -> success event with stable id", async()=>{
   const d=new ToolDispatcher(reg());
   const o=await d.dispatch({toolName:"fetch_url", argsText:"url: data:text/plain,hi", isLocalSession:true});
   expect(o.executed).toBe(true);
   expect(o.event.success).toBe(true);
   expect(o.event.output).toBe("hi");
   expect(o.event.failureKind).toBeUndefined();
   expect(typeof o.event.durationMs).toBe("number");
   // R4: result event id is a deterministic stableId
   expect(o.event.id).toBe(stableId("result","fetch_url|ok"));
 });

 it("malformed args block -> bad_args failure, not a throw", async()=>{
   const d=new ToolDispatcher(reg());
   // a block with a no-colon line is rejected by ToolArgsParser
   const o=await d.dispatch({toolName:"local_file_read", argsText:"path: /x"+NL+"continuation without colon"});
   expect(o.executed).toBe(false);
   expect(o.event.success).toBe(false);
   expect(o.event.failureKind).toBe("bad_args");
 });

 it("executes a file tool end-to-end (hermetic temp)", async()=>{
   const {tmpdir}=await import("os");
   const {join}=await import("path");
   const {writeFileSync,rmSync}=await import("fs");
   const p=join(tmpdir(),"ac_disp_"+process.pid+".txt");
   writeFileSync(p,"alpha"+NL+"beta","utf-8");
   try{
     const d=new ToolDispatcher(reg());
     const o=await d.dispatch({toolName:"local_file_read", argsText:"path: "+p, isLocalSession:true});
     expect(o.executed).toBe(true);
     expect(o.event.success).toBe(true);
     expect(o.event.output).toContain("alpha");
     expect(o.event.output).toContain("beta");
   } finally { rmSync(p,{force:true}); }
 });
 });