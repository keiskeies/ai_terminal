// tools/demo_web.mjs - visible GUI host for agent_core (browser UI; no Flutter SDK needed).
//
//   npm run web  -> serves http://127.0.0.1:18788, a live chat console driving the
//   REAL child (node dist/index.js) over the production stdio wire protocol.
//
// Stack: browser UI (SSE) <-> host (HTTP + JSONL RPC driver) <-> child dist/index.js
//        <-> local mock OpenAI-compatible LLM (SSE, 2-turn script from your goal).
// Dangerous goals (rm/删除) hit the ask-mode gate -> UI allow/deny dialog ->
// answered over rpc:confirm, exactly like the Flutter app would.
import {createServer} from "node:http";
import {writeFileSync, existsSync, unlinkSync} from "node:fs";
import * as fs from "node:fs";
import {spawn} from "node:child_process";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const WEB_PORT = 18788;
const LLM_PORT = 18787;
const TARGET = join(ROOT, "demo_web_target.txt");
const KW = {thought: "\u601d\u8003:", command: "\u547d\u4ee4:", answer: "\u56de\u7b54:", action: "\u52a8\u4f5c:"};

// goal -> 2-turn ReAct script (one command turn, then finish)
let Q = [];
const FINISH = KW.answer + " \u4efb\u52a1\u5b8c\u6210\u3002" + "\n" + KW.action + " finish";
function buildScript(goal) {
  const g = String(goal || "");
  const safe = g.replace(/[^0-9A-Za-z\u4e00-\u9fff ,.:]/g, " ").slice(0, 40);
  let cmd = "echo " + safe;
  let note = "\u5f00\u59cb\u6267\u884c\u76ee\u6807\u3002";
  if (/rm|del|\u5220\u9664|\u6e05\u7406/.test(g)) { writeFileSync(TARGET, "web demo temp\n"); cmd = "rm demo_web_target.txt"; note = "\u6e05\u7406\u4e34\u65f6\u6587\u4ef6\u3002"; }
  else if (/ls|dir|\u5217\u51fa|\u76ee\u5f55|\u6587\u4ef6/.test(g)) { cmd = "ls"; note = "\u5217\u51fa\u5f53\u524d\u76ee\u5f55\u3002"; }
  else if (/date|time|\u65f6\u95f4|\u65e5\u671f/.test(g)) { cmd = "Get-Date"; note = "\u67e5\u770b\u7cfb\u7edf\u65f6\u95f4\u3002"; }
  Q = [KW.thought + " " + note + "\n" + KW.command + " " + cmd, FINISH];
}
buildScript("\u4f60\u597d");

const DONE = String.fromCharCode(91) + "DONE" + String.fromCharCode(93);
let turn = 0;
const llm = createServer((req, res) => {
  let body = "";
  req.on("data", (d) => { body += d; });
  req.on("end", () => {
    if (!req.url.endsWith("/chat/completions")) { res.writeHead(404); res.end(); return; }
    const text = Q[Math.min(turn, Q.length - 1)];
    turn++;
    res.writeHead(200, {"content-type": "text/event-stream"});
    for (const ch of text.split("\n")) {
      res.write("data: " + JSON.stringify({choices: [{delta: {content: ch + "\n"}}]}) + "\n\n");
    }
    res.write("data: " + DONE + "\n\n");
    res.end();
  });
});
await new Promise((r) => llm.listen(LLM_PORT, "127.0.0.1", r));

// ── real child + wire driver ───────────────────────────────────────────
const child = spawn(process.execPath, ["dist/index.js"], {cwd: ROOT, stdio: ["pipe", "pipe", "pipe"]});
child.stderr.resume();
let buf = "";
const pending = new Map();
let seq = 0;
function req(method, params) {
  const id = "h-" + (++seq);
  return new Promise((resolve, reject) => {
    pending.set(id, resolve);
    child.stdin.write(JSON.stringify({jsonrpc: "2.0", id, method, params}) + "\n");
    setTimeout(() => reject(new Error("timeout " + method)), 30000);
  });
}
const sseClients = new Set();
function bcast(o) { for (const res of sseClients) { try { res.write("data: " + JSON.stringify(o) + "\n\n"); } catch {} } }
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
    bcast({kind: "wire", method: m.method, params: m.params});
  }
});

let taskSeq = 0;
const MODEL = {provider: "openai", model: "demo-mock", apiKey: "sk-demo", baseUrl: "http://127.0.0.1:" + LLM_PORT + "/v1"};
function sendJson(res, code, obj) { res.writeHead(code, {"content-type": "application/json; charset=utf-8"}); res.end(JSON.stringify(obj)); }
const web = createServer((req, res) => {
  let body = "";
  req.on("data", (d) => { body += d; });
  req.on("end", async () => {
    try {
      if (req.url === "/" || req.url.startsWith("/index")) { res.writeHead(200, {"content-type": "text/html; charset=utf-8"}); res.end(HTML); return; }
      if (req.url === "/events") {
        res.writeHead(200, {"content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive"});
        res.write("data: {\"kind\":\"hello\"}\n\n");
        sseClients.add(res);
        req.on("close", () => sseClients.delete(res));
        return;
      }
      if (req.url === "/start") {
        const goal = String(JSON.parse(body || "{}").goal || "");
        buildScript(goal);
        turn = 0;
        const id = "web-" + (++taskSeq);
        const r = await req2("rpc:startTask", {taskId: id, goal, hostId: "local", modelConfig: MODEL, permissionMode: "ask", maxSteps: 6});
        sendJson(res, 200, {ok: true, taskId: id, ack: r.result});
        return;
      }
      if (req.url === "/confirm") {
        const p = JSON.parse(body || "{}");
        const r = await req2("rpc:confirm", {taskId: p.taskId, confirmId: p.confirmId, decision: p.decision});
        sendJson(res, 200, {ack: r.result});
        return;
      }
      if (req.url === "/state") { const r = await req2("rpc:getState", {}); sendJson(res, 200, r.result); return; }
      res.writeHead(404); res.end();
    } catch (e) { sendJson(res, 500, {ok: false, error: String(e && e.message || e)}); }
  });
});
function req2(m, p) { return req(m, p); }
await new Promise((r) => web.listen(WEB_PORT, "127.0.0.1", r));
console.log("web console: http://127.0.0.1:" + WEB_PORT);
const HTML = fs.readFileSync(join(ROOT, "tools", "web_console.html"), "utf8");
child.on("close", (code) => {
  bcast({kind: "child", note: "child exited code=" + code});
  console.log("child exited code=" + code);
  llm.close();
  web.close();
  if (existsSync(TARGET)) unlinkSync(TARGET);
});
