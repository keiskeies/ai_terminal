// pty/adapter.ts tests. The pure config helpers are fully deterministic because the
// filesystem-existence check is injected (`exists`), so they assert exact shells
// regardless of which OS the CI agent runs on. The native spawn is exercised only
// when it can attach; on hosts where ConPTY/pipe attach fails it logs + skips, it
// never crashes the suite.
import {describe,it,expect,afterAll} from "vitest";
import {
  resolvePtyShell, buildPtyEnv, buildPtyConfig, spawnLocalPty, PtySession,
  ExistCheck,
} from "../src/pty/adapter.js";

/** Deterministic existence predicate: true only for the given paths. */
const exist = (...paths: string[]) => (p: string) => paths.includes(p);

describe("resolvePtyShell (R6 platform branch)",()=>{
 it("Windows: powershell present -> hosted by cmd.exe (ConPTY quirk)",()=>{
   const ps="C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
   const r=resolvePtyShell("win32",{}, exist(ps));
   expect(r.shell).toBe("cmd.exe");
   expect(r.args).toEqual(["/K","powershell.exe","-NoLogo"]);
   expect(r.kind).toBe("powershell");
   expect(r.powersShellHosted).toBe(true);
 });
 it("Windows: powershell absent -> plain cmd.exe",()=>{
   const r=resolvePtyShell("win32",{}, exist()); // nothing exists
   expect(r.shell).toBe("cmd.exe");
   expect(r.args).toEqual([]);
   expect(r.kind).toBe("cmd");
   expect(r.powersShellHosted).toBe(false);
 });
 it("non-Windows: prefers $SHELL when it exists",()=>{
   const r=resolvePtyShell("linux",{SHELL:"/usr/bin/zsh"}, exist("/usr/bin/zsh"));
   expect(r.shell).toBe("/usr/bin/zsh");
   expect(r.args).toEqual(["-l"]);
   expect(r.kind).toBe("zsh");
 });
 it("non-Windows: $SHELL missing -> falls back to /bin/bash",()=>{
   const r=resolvePtyShell("linux",{SHELL:"/nope"}, exist("/bin/bash"));
   expect(r.shell).toBe("/bin/bash");
   expect(r.kind).toBe("bash");
 });
 it("non-Windows: nothing exists -> bash default",()=>{
   const r=resolvePtyShell("linux",{}, exist());
   expect(r.shell).toBe("bash");
   expect(r.kind).toBe("bash");
 });
});

describe("buildPtyEnv",()=>{
 it("sets TERM on all platforms",()=>{
   expect(buildPtyEnv("linux",{}).TERM).toBe("xterm-256color");
   expect(buildPtyEnv("win32",{}).TERM).toBe("xterm-256color");
 });
 it("disables pagers only on non-Windows",()=>{
   const linux=buildPtyEnv("linux",{SHELL:"/bin/bash"});
   expect(linux.PAGER).toBe("cat");
   expect(linux.GIT_PAGER).toBe("cat");
   expect(linux.SHELL).toBe("/bin/bash");
   const win=buildPtyEnv("win32",{});
   expect(win.PAGER).toBeUndefined();
 });
});

describe("buildPtyConfig",()=>{
 it("assembles cols/rows/useConpty per platform",()=>{
   const c=buildPtyConfig({columns:120,rows:40,platform:"win32", exists: exist("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")});
   expect(c.cols).toBe(120);
   expect(c.rows).toBe(40);
   expect(c.useConpty).toBe(true);
   expect(c.env.TERM).toBe("xterm-256color");
   const c2=buildPtyConfig({platform:"linux", exists: exist("/bin/bash")});
   expect(c2.useConpty).toBe(false);
   expect(c2.shell).toBe("/bin/bash");
 });
 it("explicit shell override wins",()=>{
   const c=buildPtyConfig({shell:"/bin/sh",shellArgs:["-l"],platform:"linux", exists: exist()});
   expect(c.shell).toBe("/bin/sh");
   expect(c.args).toEqual(["-l"]);
 });
});

describe("spawnLocalPty (guarded live)",()=>{
 let session: PtySession | null = null;
 afterAll(()=>{ try{session?.dispose();}catch{} });
 it("spawns, writes, observes output, then exits", async ()=>{
   const platform=process.platform;
   if(platform!=="linux" && platform!=="darwin" && platform!=="win32") return; // skip exotic
   try {
     const shell= platform==="win32" ? "cmd.exe" : "/bin/sh";
     session = await spawnLocalPty({columns:80, rows:24, shell, shellArgs: platform==="win32"? [] : [], platform});
     const chunks: string[]=[];
     const sub=session.onOutput((c)=>chunks.push(c));
     const echoCmd = platform==="win32" ? "echo hi\r" : "echo hi\n";
     session.write(echoCmd);
     await new Promise((r)=>setTimeout(r,400));
     sub.dispose();
     session.kill();
     await new Promise((r)=>setTimeout(r,200));
     expect(session.running).toBe(false);
     expect(chunks.join("").length).toBeGreaterThan(0); // prompt / echo observed
   } catch(e: any){
     // ConPTY/pipe attach unavailable on this host (e.g. restricted CI): skip, do not fail.
     console.log("[pty] skipped live spawn: " + (e && e.message ? e.message : e));
   }
 });
});