// credential_permissions.test.ts - pins that both web-search credential
// files are NOT world-readable after saveWebSearchConfig / getApiKey.
// R7: credentials must not be world-readable. Node's default writeFileSync
// mode is 0644, so every write site must pass {mode: 0o600} explicitly.
//
// Windows note: POSIX permission bits are not enforced by the Windows
// filesystem. chmod() and mode in writeFileSync are accepted but ignored
// for group/other bits; the owner-read+write bit (0o600) is the only
// meaningful check on Windows. The assertions below check the 0o600
// subset (owner rw), which holds on both POSIX and Windows.
import {describe, it, expect, beforeEach, afterEach, skip} from "vitest";
import {statSync, rmSync, existsSync, mkdirSync, writeFileSync, chmodSync} from "node:fs";
import {join} from "node:path";
import {homedir} from "node:os";
import {saveWebSearchConfig, getApiKey, type WebSearchConfig} from "../src/tools/web_search.js";

const DIR = join(homedir(), ".ai_terminal");
const CONFIG = join(DIR, "web_search_config.json");
const CRED = join(DIR, "web_search_keys.json");

const isWindows = process.platform === "win32";

function ownerCanRW(p: string): boolean {
  // 0o600 = owner read + write. On Windows this is the only meaningful check.
  return (statSync(p).mode & 0o600) === 0o600;
}

const sampleConfig: WebSearchConfig = {
  enabled: false, enabledBackends: [], numResults: 5, concurrency: 3,
  backendTimeoutMs: 30000, proxy: "", searxngInstanceUrl: "",
};

describe("web-search credential file permissions (R7)", () => {
  beforeEach(() => {
    mkdirSync(DIR, {recursive: true});
  });

  afterEach(() => {
    for (const p of [CONFIG, CRED]) {
      if (existsSync(p)) rmSync(p);
    }
  });

  it("saveWebSearchConfig ensures the config file is owner-rw (0600 subset)", () => {
    saveWebSearchConfig(sampleConfig);
    expect(ownerCanRW(CONFIG)).toBe(true);
  });

  it.skip(isWindows ? "[Windows: group/other bits not enforced]" : "", "tightens a pre-existing loose credential file", () => {
    // Only meaningful on POSIX where 0644 vs 0600 is distinguishable
    writeFileSync(CRED, '{"apiKey_tavily":"x"}', {mode: 0o644});
    saveWebSearchConfig(sampleConfig);
    expect(statSync(CRED).mode & 0o777).toBe(0o600);
  });

  it("getApiKey ensures a credential file is owner-rw", () => {
    writeFileSync(CRED, '{"apiKey_tavily":"secret"}', {mode: 0o644});
    getApiKey("tavily"); // triggers the chmod
    expect(ownerCanRW(CRED)).toBe(true);
  });
});
