// test/fixtures/verify.mjs - run after build; validates stableId against the fixture
import {fnv1a64DartCompat} from "../../dist/index.js";
import {readFileSync} from "fs";

const p = "test/fixtures/stable_id_1000.jsonl";
const lines = readFileSync(p, "utf-8").split("\n").filter(Boolean);
let pass = 0, fail = 0;
for (const line of lines) {
  const i = line.lastIndexOf(" evt_");
  const input = JSON.parse(line.slice(0, i).trim());
  const want = line.slice(i + 1).trim();
  const got = "evt_" + fnv1a64DartCompat(input).toString(16);
  if (got === want) pass++; else { fail++; console.error("MISMATCH:", input, got, "want", want); }
}
console.log("fixture:", pass, "ok,", fail, "failed");
process.exit(fail ? 1 : 0);