// Unit tests for the local-file I/O + trash helper utilities
// (agent_core/src/utils/local_file_ops.ts), ported from local_file_ops.dart.
import {describe,it,expect,beforeAll,afterAll} from "vitest";
import {
  decodeEscapedText, decodeContent, countOccurrences, formatByteSize,
  looksLikeWindowsLocalPath, looksLikePosixRemotePath,
  patchLocalFile, writeLocalFile, TRASH_DIR_NAME,
  trashEntriesFromRestorePaths, isTrashEntryDir,
} from "../src/utils/local_file_ops.js";
import {mkdirSync,writeFileSync,rmSync,readFileSync,existsSync,statSync} from "fs";
import {tmpdir} from "os";
import {join} from "path";

let T="";
beforeAll(()=>{
  T = join(tmpdir(),"ac_lfo_" + process.pid);
  rmSync(T,{recursive:true,force:true});
  mkdirSync(T,{recursive:true});
});
afterAll(()=>rmSync(T,{recursive:true,force:true}));

describe("decodeEscapedText",()=>{
  it("expands \\n \\r \\t and \\\\",()=>{
    expect(decodeEscapedText("a\\nb\\rc\\td\\\\e")).toBe("a\nb\rc\td\\e");
  });
  it("leaves plain text untouched",()=>{
    expect(decodeEscapedText("plain")).toBe("plain");
  });
});

describe("decodeContent",()=>{
  it("prefers base64 when provided and valid",()=>{
    const r = decodeContent("ignored", Buffer.from("hi\n").toString("base64"));
    expect(r.error).toBeUndefined();
    expect(Buffer.from(r.bytes).toString("utf-8")).toBe("hi\n");
  });
  it("falls back to plain text when no base64",()=>{
    const r = decodeContent("plain", "");
    expect(Buffer.from(r.bytes).toString("utf-8")).toBe("plain");
  });
  it("reports an error for invalid base64",()=>{
    const r = decodeContent("", "not-valid-base64!!!");
    expect(r.error).toBeDefined();
  });
});

describe("countOccurrences",()=>{
  it("counts non-overlapping occurrences",()=>{
    expect(countOccurrences("aaaa","aa")).toBe(2);
    expect(countOccurrences("x","y")).toBe(0);
    expect(countOccurrences("abc","",)).toBe(0);
  });
});

describe("formatByteSize",()=>{
  it("formats B/KB/MB tiers",()=>{
    expect(formatByteSize(100)).toBe("100 B");
    expect(formatByteSize(2048)).toBe("2.0 KB");
    expect(formatByteSize(5*1024*1024)).toBe("5.0 MB");
  });
});

describe("path-shape helpers",()=>{
  it("detects Windows local vs posix remote",()=>{
    expect(looksLikeWindowsLocalPath("C:\\Windows\\x")).toBe(true);
    expect(looksLikeWindowsLocalPath("C:/foo")).toBe(true);
    expect(looksLikeWindowsLocalPath("/etc/x")).toBe(false);
    expect(looksLikePosixRemotePath("/etc/x")).toBe(true);
    expect(looksLikePosixRemotePath("~/home")).toBe(true);
    expect(looksLikePosixRemotePath("relative")).toBe(false);
  });
});

describe("patchLocalFile",()=>{
  it("replaces a unique substring in a real file",()=>{
    const f = join(T,"patch.txt");
    writeFileSync(f,"old\n");
    const r = patchLocalFile({path:f, oldText:"old", newText:"new"});
    expect(r.success).toBe(true);
    expect(readFileSync(f,"utf-8")).toBe("new\n");
    expect(r.oldText).toBe("old");
    expect(r.newText).toBe("new");
  });
  it("fails when the file is missing",()=>{
    const r = patchLocalFile({path:join(T,"nope"), oldText:"a", newText:"b"});
    expect(r.success).toBe(false);
  });
  it("fails when oldText is ambiguous (count != 1)",()=>{
    const f = join(T,"amb.txt");
    writeFileSync(f,"dup\ndup\n");
    const r = patchLocalFile({path:f, oldText:"dup", newText:"x"});
    expect(r.success).toBe(false);
  });
});

describe("writeLocalFile",()=>{
  it("writes and reports byte count",()=>{
    const f = join(T,"w.txt");
    const r = writeLocalFile({path:f, bytes:Buffer.from("hello")});
    expect(r.success).toBe(true);
    expect(r.bytesWritten).toBe(5);
    expect(readFileSync(f,"utf-8")).toBe("hello");
  });
  it("append to a missing file fails",()=>{
    const f = join(T,"a.txt");
    const r = writeLocalFile({path:f, bytes:Buffer.from("x"), append:true});
    expect(r.success).toBe(false);
    expect(r.error).toBeDefined();
  });
  it("creates a .bak backup when overwriting an existing file",()=>{
    const f = join(T,"ovr.txt");
    writeFileSync(f,"orig");
    const r = writeLocalFile({path:f, bytes:Buffer.from("over")});
    expect(r.success).toBe(true);
    expect(r.backupPath).toBeDefined();
    expect(existsSync(r.backupPath as string)).toBe(true);
  });
});

describe("trash helpers",()=>{
  it("trashEntriesFromRestorePaths derives entry dirs and TRASH_DIR_NAME",()=>{
    expect(TRASH_DIR_NAME).toBe(".ai_terminal_trash");
    const entry = join(T,TRASH_DIR_NAME,"123");
    const entries = trashEntriesFromRestorePaths([entry+"/file.txt"]);
    expect(entries).toContain(entry);
    expect(isTrashEntryDir(entry)).toBe(true);
    // the trash root itself is NOT an entry dir
    expect(isTrashEntryDir(join(T,TRASH_DIR_NAME))).toBe(false);
  });
});
