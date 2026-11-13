#!/usr/bin/env node
// tools/demo_run.mjs - whole-stack demo of agent_core (doc sec.2 wire protocol).
//
//   node tools/demo_run.mjs      (or: npm run demo)
//
// Brings up the ENTIRE runnable stack in one shot, no API key needed:
//   1. local OpenAI-compatible mock LLM (SSE /chat/completions)
//   2. the real built child: node dist/index.js (stdio JSONL RPC server)
//   3. this host driver: spawns the child, speaks the wire protocol,
//      renders every event like the Flutter UI would, and answers the
//      confirm gate over rpc:confirm when the ask-mode gate parks it.
//
// Task 1: SAFE command path (echo) -> executes directly, finishes.
// Task 2: WARN command path (rm of a temp file) -> ask gate parks the
// task in waiting_confirm, host approves via rpc:confirm, command runs.
// All canned CJK ReAct text is written as unicode escapes (ASCII file).

import {createServer} from "node:http";
import {writeFileSync, unlinkSync, existsSync} from "node:fs";
import {spawn} from "node:child_process";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const PORT = 18787;
const DONE = "[DONE]";
const TARGET = join(ROOT, "demo_confirm_target.txt");

const KW = {
  thought: "\u601d\u8003:",   // 思考
  command: "\u547d\u4ee4:",   // 命令
  answer:  "\u56de\u7b54:",   // 回答
  action:  "\u52a8\u4f5c:",   // 动作
};

const SCRIPTS = [
  KW.thought + " \u5148\u6253\u4e2a\u54cd\u3002" + "\n" + KW.command + " echo agent-core-online",
  KW.answer + " \u547d\u4ee4\u6267\u884c\u6210\u529f\u3002" + "\n" + KW.action + " finish",
  KW.thought + " \u6e05\u7406\u4e34\u65f6\u6587\u4ef6\u3002" + "\n" + KW.command + " rm demo_confirm_target.txt",
  KW.answer + " \u4e34\u65f6\u6587\u4ef6\u5df2\u6e05\u7406\u3002" + "\n" + KW.action + " finish",
];
let turn = 0;
const server = createServer((req, res) => {
  if (req.url === "/demo-probe") { res.writeHead(200); res.end("probe-ok"); return; }
  if (!req.url.endsWith("/chat/completions")) { res.writeHead(404); res.end(); return; }
  let body = "";
  req.on("data", (d) => { body += d; });
  req.on("end", () => {
    const text = SCRIPTS[Math.min(turn, SCRIPTS.length - 1)];
    turn++;
    res.writeHead(200, {"content-type": "text/event-stream"});
    const chunks = text.split("\n");
    for (const ch of chunks) {
      const payload = {choices: [{delta: {content: ch + "\n"}}]};
      res.write("data: " + JSON.stringify(payload) + "\n\n");
    }
    res.write("data: " + DONE + "\n\n");
    res.end();
  });
});
await new Promise((r) => server.listen(PORT, "127.0.0.1", r));

// ── 2. spawn the real built child ──────────────────────────────────────
const child = spawn(process.execPath, ["dist/index.js"], {cwd: ROOT, stdio: ["pipe", "pipe", "pipe"]});
let buf = "";
const pending = new Map();
let seq = 0;
function send(o) { child.stdin.write(JSON.stringify(o) + "\n"); }
function req(method, params) {
  const id = "h-" + (++seq);
  return new Promise((resolve, reject) => {
    pending.set(id, resolve);
    send({jsonrpc: "2.0", id, method, params});
    setTimeout(() => reject(new Error("timeout " + method)), 20000);
  });
}
child.stdout.on("data", (d) => {
  buf += d.toString("utf8");
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    let m;
    try { m = JSON.parse(line); } catch { continue; }
    if (m.id !== undefined && (m.result !== undefined || m.error !== undefined)) {
      const f = pending.get(m.id);
      if (f) { pending.delete(m.id); f(m); }
      continue;
    }
    onNotification(m);
  }
});

// ── 3. host-side rendering + confirm answering ─────────────────────────
let confirmSeen = 0;
function onNotification(m) {
  if (m.method === "evt:agentEvent") {
    const e = m.params.event;
    let tail = "";
    if (typeof e.command === "string") tail = " :: " + e.command;
    else if (typeof e.text === "string") tail = " :: " + e.text.slice(0, 80);
    else if (typeof e.output === "string") tail = " :: " + e.output.trim().slice(0, 80);
    else if (typeof e.summary === "string") tail = " :: " + e.summary.slice(0, 80);
    console.log("  [event]  " + e.type + (e.finishState ? " (" + e.finishState + ")" : "") + tail);
  } else if (m.method === "evt:taskState") {
    console.log("  [state]  " + JSON.stringify(m.params.state));
  } else if (m.method === "evt:confirmRequest") {
    confirmSeen++;
    const p = m.params;
    console.log("  [confirm] risk=" + p.riskLevel + " prompt=" + String(p.prompt).slice(0, 100));
    console.log("  [host]    user clicked OK -> rpc:confirm ok");
    setTimeout(() => {
      req("rpc:confirm", {taskId: p.taskId, confirmId: p.confirmId, decision: "ok"})
        .then((r) => console.log("  [confirm] woken=" + JSON.stringify(r.result))
        ).catch((e) => console.log("  [confirm] FAIL " + e.message));
    }, 400);
  } else if (m.method === "err:uncaught") {
    console.log("  [uncaught] " + m.params.message);
  }
}

const MODEL = {
  provider: "openai",
  model: "demo-mock",
  apiKey: "sk-demo",
  baseUrl: "http://127.0.0.1:" + PORT + "/v1",
};

async function runTask(taskId, goal) {
  const r = await req("rpc:startTask", {taskId, goal, hostId: "local", modelConfig: MODEL, permissionMode: "ask", maxSteps: 4});
  console.log("  [start]  " + JSON.stringify(r.result));
  for (let k = 0; k < 40; k++) {
    await new Promise((res) => setTimeout(res, 250));
    const st = await req("rpc:getState", {});
    if (st.result.status === "idle") return;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

console.log("=== agent_core whole-stack demo ===");
console.log("mock LLM listening on 127.0.0.1:" + PORT);

// ── 4. the demo itself ─────────────────────────────────────────────────
const pong = await req("rpc:ping", {});
console.log("[handshake] protocolVersion=" + pong.result.protocolVersion);

console.log("");
console.log("--- task 1: safe command path (echo) ---");
await runTask("demo-1", "demo goal 1");
await sleep(400);

console.log("");
console.log("--- task 2: warn path (rm) -> ask gate -> host confirms ---");
writeFileSync(TARGET, "temporary demo file\n");
console.log("  [host]    created " + TARGET.replace(ROOT, ".") + " exists=" + existsSync(TARGET));
await runTask("demo-2", "demo goal 2");
await sleep(400);
console.log("  [host]    target file exists=" + existsSync(TARGET) + " (false = the confirmed rm really ran)");

console.log("");
console.log("confirmRequests seen: " + confirmSeen);
const st = await req("rpc:getState", {});
console.log("final state: " + st.result.status);
child.stdin.end();
child.on("close", (code) => {
  server.close();
  console.log("child exited code=" + code);
  if (existsSync(TARGET)) unlinkSync(TARGET);
  process.exit(0);
});
setTimeout(() => { child.kill(); process.exit(1); }, 60000);
